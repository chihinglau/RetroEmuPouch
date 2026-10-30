#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
GamePouch 本地游戏库管理器 (桌面版)
===================================

统一管理本地的 ROM / BIOS / 金手指三类资源, 纯本地、离线、零外部依赖
(仅 Python 3 标准库 + tkinter)。

功能
----
* 扫描本地目录: 任选根目录, 自动识别 roms/ (含 GBA/NES/NeoGeo/CPS1/CPS2 子目录
  或任意扁平目录)、bios/、chats/。
* 分类展示: 按平台(GBA/NES/NeoGeo/CPS1/CPS2)归类, 列出名称/平台/大小/CRC32/
  内部标题/金手指数/依赖 BIOS。
* 关联展示:
  - 金手指与游戏按「文件名主干」一一对应 (chats/<主干>.cht),
    并回退到 GamePouch 原生 cheats.json (按 ROM 的 CRC32 键控)。
  - BIOS 按平台标注被谁需要 (NeoGeo<-neogeo.zip, CPS1/2<-qsound.zip)。
* 检索: 名称/内部标题 模糊搜索 + 平台/分类筛选 + 列排序 + 「仅显示有金手指」。
* 整理: 打开所在文件夹、导出清单(CSV/JSON)、重新关联金手指(调用 sync_cheats.py)。
* 联网: 一键为缺失金手指的 ROM 上网检索并适配 (online_cheats.py)。
* 同步: 把 ROM / 金手指 / BIOS 送到手机上的 App —— 支持 USB(adb) 直推与
  局域网「伙伴」由手机主动拉取两种方式 (phone_sync.py / peer_host.py)。

界面配色
--------
不同模块/状态用颜色区分: 平台各有主色(见 PLATFORM_COLOR), 行底色区分
"有金手指 / 缺金手指", 顶部统计卡片与状态条按语义着色。

CRC32 说明
----------
ROM 的 CRC32 与 GamePouch 手机端完全一致(整个文件的 IEEE 802.3 CRC32,
不剥 NES 头), 是金手指与元数据的关联键。全量扫描 6GB 需要十几秒且只在首次
发生: 结果按 (路径, 大小, 修改时间) 缓存, 再次扫描瞬时完成; 扫描在后台线程
进行, UI 始终可响应。
"""
from __future__ import annotations

import csv
import json
import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
import zlib
from tkinter import filedialog, messagebox, ttk

# 复用 chatsync 里的金手指解析/CRC/GBA 标题读取, 避免两套实现漂移
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, '..', 'chatsync')))
from sync_cheats import (  # noqa: E402
    crc32_file, gba_internal_title, parse_cht_text, to_cht_text,
)
sys.path.insert(0, _HERE)
import online_cheats  # noqa: E402
import peer_host  # noqa: E402
import phone_sync  # noqa: E402
import library_meta  # noqa: E402
from library_meta import GameMeta  # noqa: E402

# --------------------------------------------------------------- 常量

DEFAULT_ROOT = os.path.abspath(
    os.path.join(_HERE, '..', '..', '.tools', 'gstest'))

# 扩展名 -> 平台(扁平目录时的推断依据)
EXT_PLATFORM = {
    '.gba': 'gba', '.nes': 'nes', '.fds': 'nes',
    '.zip': 'arcade',
}
# 子目录名 -> 平台
DIR_PLATFORM = {
    'gba': 'gba', 'nes': 'nes', 'neogeo': 'neogeo',
    'cps1': 'cps1', 'cps2': 'cps2',
}
PLATFORM_LABEL = {
    'gba': 'GBA', 'nes': 'NES', 'neogeo': 'NeoGeo',
    'cps1': 'CPS1', 'cps2': 'CPS2', 'arcade': '街机', '': '未分类',
}
# 各平台运行所需的 BIOS(与项目 skills.md「多 BIOS 列表」一致)
PLATFORM_BIOS = {
    'neogeo': ['neogeo.zip'],
    'cps1': ['qsound.zip'],
    'cps2': ['qsound.zip'],
}
BIOS_DESC = {
    'neogeo.zip': 'NeoGeo 全系必需',
    'qsound.zip': 'CPS1/CPS2(Q-Sound)必需',
}

ROM_EXTS = tuple(EXT_PLATFORM.keys())

# ------------------------------------------------------------ 配色方案

#: 界面骨架色
C = {
    'bg': '#eef2f8',        # 窗口底色
    'panel': '#ffffff',     # 卡片/面板
    'ink': '#1f2937',       # 主文字
    'muted': '#6b7280',     # 次要文字
    'line': '#dbe3ef',      # 分隔线
    'brand': '#2563eb',     # 品牌蓝
    'ok': '#15803d',        # 成功绿
    'ok_bg': '#e7f8ee',
    'warn': '#b45309',      # 警告橙
    'warn_bg': '#fff5e6',
    'bad': '#b91c1c',       # 缺失红
    'bad_bg': '#fdecec',
    'info': '#0e7490',
    'info_bg': '#e0f5fb',
}

#: 各平台主色(用于行文字色 / 统计卡片 / 图例)
PLATFORM_COLOR = {
    'gba': '#6d28d9',     # 紫
    'nes': '#b91c1c',     # 红
    'neogeo': '#0e7490',  # 青
    'cps1': '#c2410c',    # 橙
    'cps2': '#a16207',    # 琥珀
    'arcade': '#374151',  # 灰
    '': '#6b7280',
}

#: 各平台的浅色底(用于图例块 / 卡片)
PLATFORM_TINT = {
    'gba': '#ede9fe',
    'nes': '#fee2e2',
    'neogeo': '#cffafe',
    'cps1': '#ffedd5',
    'cps2': '#fef3c7',
    'arcade': '#e5e7eb',
    '': '#f3f4f6',
}


def human_size(n: int) -> str:
    if n >= 1024 ** 3:
        return '%.2f GB' % (n / 1024 ** 3)
    if n >= 1024 ** 2:
        return '%.1f MB' % (n / 1024 ** 2)
    if n >= 1024:
        return '%.0f KB' % (n / 1024)
    return '%d B' % n


def fast_crc32_file(path: str) -> str:
    """与 GamePouch 一致的 CRC32(整个文件)。"""
    return crc32_file(path)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title('趣玩匣 GamePouch · 本地游戏库管理')
        self.geometry('1280x820')
        self.minsize(1040, 640)

        self.root_dir = tk.StringVar(value=DEFAULT_ROOT)
        self.query = tk.StringVar()
        self.plat_filter = tk.StringVar(value='')
        self.cat_filter = tk.StringVar(value='')
        self.only_cheat = tk.BooleanVar(value=False)
        self.only_missing = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value='就绪')

        self.games = []          # 游戏记录
        self.bios = []           # BIOS 记录
        self.orphan_cheats = []  # 孤立金手指
        self.cheat_by_crc = {}   # CRC -> [cheat]
        self.cur_cheat_items = None   # 当前编辑的金手指列表(指向 g['cheats'] 等)
        self.meta = GameMeta()   # 游戏元数据(中文名/封面)查询器
        self._icon_imgs = {}     # path -> PhotoImage(避免 GC)
        self.cur_cheat_target = None  # ('G', game) / ('O', orphan)
        self.cur_cheat_display = ''   # 当前选中项用于诊断提示的主干/文件名
        self.crc_cache = {}
        self._q = queue.Queue()
        self._scanning = False
        self._warn_msg = ''   # 最近一次扫描的非致命提示(如元数据索引缺失)

        self._build_style()
        self._build_menu()
        self._build_top()
        self._build_notebook()
        self._build_status()
        self._bind_keys()

        self._load_crc_cache()
        self.after(120, lambda: self.scan(rescan=False))

    # ----------------------------------------------------------- 样式
    def _build_style(self):
        st = ttk.Style(self)
        for theme in ('clam', 'vista', 'xpnative'):
            if theme in st.theme_names():
                try:
                    st.theme_use(theme)
                    break
                except Exception:
                    pass
        f9 = ('Microsoft YaHei UI', 9)
        st.configure('TFrame', background=C['bg'])
        st.configure('Panel.TFrame', background=C['panel'], relief='flat')
        st.configure('Top.TFrame', background='#16233a')
        st.configure('Header.TLabel', background=C['bg'], font=(
            'Microsoft YaHei UI', 9, 'bold'))
        st.configure('TLabel', font=f9, background=C['bg'],
                     foreground=C['ink'])
        st.configure('Panel.TLabel', background=C['panel'],
                     foreground=C['ink'], font=f9)
        st.configure('Muted.TLabel', foreground=C['muted'],
                     background=C['bg'], font=('Microsoft YaHei UI', 8))
        st.configure('TButton', font=f9, padding=(8, 4))
        st.configure('Accent.TButton', font=('Microsoft YaHei UI', 9, 'bold'))
        st.map('Accent.TButton',
               background=[('!disabled', C['brand']), ('active', '#1d4ed8')],
               foreground=[('!disabled', '#ffffff')])
        st.map('Danger.TButton',
               background=[('!disabled', '#dc2626'), ('active', '#b91c1c')],
               foreground=[('!disabled', '#ffffff')])
        st.configure('Treeview', font=('Consolas', 9), rowheight=23,
                     fieldbackground=C['panel'], borderwidth=0)
        st.configure('Treeview.Heading',
                     font=('Microsoft YaHei UI', 9, 'bold'))
        st.map('Treeview', background=[('selected', '#cfe0ff')],
               foreground=[('selected', '#111827')])
        st.configure('Brand.TLabel', font=('Microsoft YaHei UI', 14, 'bold'),
                     background='#16233a', foreground='#ffffff')
        st.configure('Sub.TLabel', foreground='#a9b7cc',
                     background='#16233a', font=('Microsoft YaHei UI', 8))
        st.configure('TCheckbutton', background=C['bg'], font=f9)
        st.configure('TNotebook.Tab', font=('Microsoft YaHei UI', 9, 'bold'),
                     padding=(12, 6))
        self.configure(bg=C['bg'])

        # --- 行状态底色 + 平台文字色
        self.row_tags = {}
        for plat, fg in PLATFORM_COLOR.items():
            for has in (True, False):
                tag = 'p_%s_%s' % (plat or 'none', 'y' if has else 'n')
                self.row_tags[(plat, has)] = tag

    def _apply_row_tags(self, tv):
        for (plat, has), tag in self.row_tags.items():
            tv.tag_configure(tag,
                             foreground=PLATFORM_COLOR.get(plat, C['ink']),
                             background=C['ok_bg'] if has else C['bad_bg'])
        tv.tag_configure('orphan', foreground=C['warn'],
                         background=C['warn_bg'])

    def _build_menu(self):
        m = tk.Menu(self)
        fm = tk.Menu(m, tearoff=0)
        fm.add_command(label='选择根目录…', command=self.choose_root)
        fm.add_command(label='重新扫描', command=lambda: self.scan(rescan=True),
                       accelerator='F5')
        fm.add_separator()
        fm.add_command(label='重新关联金手指(调用 sync_cheats.py)',
                       command=self.resync_cheats)
        fm.add_separator()
        fm.add_command(label='导出清单 (CSV)', command=lambda: self.export('csv'))
        fm.add_command(label='导出清单 (JSON)', command=lambda: self.export('json'))
        fm.add_separator()
        fm.add_command(label='退出', command=self.destroy)
        m.add_cascade(label='文件', menu=fm)

        nm = tk.Menu(m, tearoff=0)
        nm.add_command(label='一键联网补全缺失金手指',
                       command=lambda: (self.nb.select(4),
                                        self.online_fetch()))
        nm.add_command(label='撤销联网适配', command=self.online_undo)
        m.add_cascade(label='联网', menu=nm)

        sm = tk.Menu(m, tearoff=0)
        sm.add_command(label='手机同步 (USB / 局域网)',
                       command=lambda: self.nb.select(5))
        m.add_cascade(label='同步', menu=sm)

        vm = tk.Menu(m, tearoff=0)
        vm.add_checkbutton(label='仅显示有金手指的游戏',
                           variable=self.only_cheat,
                           command=self.refresh_table)
        vm.add_checkbutton(label='仅显示缺金手指的游戏',
                           variable=self.only_missing,
                           command=self.refresh_table)
        vm.add_command(label='清空筛选', command=self.clear_filters)
        m.add_cascade(label='视图', menu=vm)

        hm = tk.Menu(m, tearoff=0)
        hm.add_command(label='关于', command=self.about)
        m.add_cascade(label='帮助', menu=hm)
        self.config(menu=m)

    def _build_top(self):
        top = ttk.Frame(self, style='Top.TFrame', padding=(12, 9))
        top.pack(fill='x')
        ttk.Label(top, text='趣玩匣 · 游戏库管理', style='Brand.TLabel').pack(
            side='left')
        ttk.Label(top, text='   ROM / 金手指 / BIOS  ·  本地整理 · 联网补全 · '
                            '手机同步',
                  style='Sub.TLabel').pack(side='left')

        right = ttk.Frame(top, style='Top.TFrame')
        right.pack(side='right')
        ttk.Label(right, text='根目录', style='Sub.TLabel').pack(side='left')
        e = ttk.Entry(right, textvariable=self.root_dir, width=48)
        e.pack(side='left', padx=(6, 4))
        ttk.Button(right, text='浏览…', command=self.choose_root).pack(side='left')
        ttk.Button(right, text='重新扫描',
                   command=lambda: self.scan(rescan=True)).pack(side='left',
                                                                padx=(4, 0))

        self._build_stats()

    def _build_stats(self):
        """顶部统计卡片: 每个模块一种颜色。"""
        strip = ttk.Frame(self, padding=(10, 8))
        strip.pack(fill='x')
        self.stat_vars = {}
        cards = [
            ('games', '游戏总数', C['brand'], '#dbeafe'),
            ('cheat', '有金手指', C['ok'], C['ok_bg']),
            ('missing', '缺金手指', C['bad'], C['bad_bg']),
            ('cmds', '金手指命令', C['info'], C['info_bg']),
            ('bios', 'BIOS', C['warn'], C['warn_bg']),
            ('orphan', '孤立金手指', '#7c3aed', '#f3e8ff'),
        ]
        for key, label, fg, bg in cards:
            v = tk.StringVar(value='0')
            self.stat_vars[key] = v
            card = tk.Frame(strip, bg=C['panel'], highlightthickness=1,
                            highlightbackground=C['line'])
            card.pack(side='left', fill='y', padx=(0, 8), ipadx=10, ipady=4)
            bar = tk.Frame(card, bg=fg, width=4)
            bar.pack(side='left', fill='y')
            body = tk.Frame(card, bg=C['panel'])
            body.pack(side='left', fill='both', padx=10, pady=4)
            tk.Label(body, textvariable=v, bg=C['panel'], fg=fg,
                     font=('Microsoft YaHei UI', 15, 'bold')).pack(anchor='w')
            tk.Label(body, text=label, bg=C['panel'], fg=C['muted'],
                     font=('Microsoft YaHei UI', 8)).pack(anchor='w')

        # 平台图例(颜色 = 平台)
        legend = tk.Frame(strip, bg=C['bg'])
        legend.pack(side='right')
        tk.Label(legend, text='平台色例 ', bg=C['bg'], fg=C['muted'],
                 font=('Microsoft YaHei UI', 8)).pack(side='left')
        for plat in ('gba', 'nes', 'neogeo', 'cps1', 'cps2', 'arcade'):
            chip = tk.Frame(legend, bg=PLATFORM_TINT.get(plat, '#eee'))
            chip.pack(side='left', padx=(0, 4))
            tk.Label(chip, text=' ' + PLATFORM_LABEL.get(plat, plat) + ' ',
                     bg=PLATFORM_TINT.get(plat, '#eee'),
                     fg=PLATFORM_COLOR.get(plat, C['ink']),
                     font=('Microsoft YaHei UI', 8, 'bold')).pack()

    def _update_stats(self):
        games = self.games
        with_cheat = [g for g in games if g['cheats']]
        n_cmd = sum(len(g['cheats']) for g in with_cheat)
        vals = {
            'games': len(games),
            'cheat': len(with_cheat),
            'missing': len(games) - len(with_cheat),
            'cmds': n_cmd,
            'bios': len(self.bios),
            'orphan': len(self.orphan_cheats),
        }
        for k, v in vals.items():
            if k in self.stat_vars:
                self.stat_vars[k].set(str(v))

    def _build_notebook(self):
        nb = ttk.Notebook(self)
        nb.pack(fill='both', expand=True, padx=8, pady=(6, 0))
        self.nb = nb

        # ---- 游戏库
        f1 = ttk.Frame(nb)
        nb.add(f1, text=' 游戏库 ')
        self._build_library_tab(f1)

        # ---- 金手指
        f2 = ttk.Frame(nb)
        nb.add(f2, text=' 金手指 ')
        self._build_cheat_tab(f2)

        # ---- BIOS
        f3 = ttk.Frame(nb)
        nb.add(f3, text=' BIOS ')
        self._build_bios_tab(f3)

        # ---- 报告
        f4 = ttk.Frame(nb)
        nb.add(f4, text=' 关联报告 ')
        self._build_report_tab(f4)

        # ---- 联网检索
        f5 = ttk.Frame(nb)
        nb.add(f5, text=' 联网检索金手指 ')
        self._build_online_tab(f5)

        # ---- 手机同步
        f6 = ttk.Frame(nb)
        nb.add(f6, text=' 手机同步 ')
        self._build_phone_tab(f6)

    def _filters_bar(self, parent, cat_values):
        bar = ttk.Frame(parent, padding=(0, 6, 0, 6))
        bar.pack(fill='x')
        ttk.Label(bar, text='🔍').pack(side='left')
        ttk.Entry(bar, textvariable=self.query, width=30).pack(
            side='left', padx=(2, 10))
        self.query.trace_add('write', lambda *_: self.refresh_table())

        ttk.Label(bar, text='平台:').pack(side='left')
        cb = ttk.Combobox(bar, textvariable=self.plat_filter, width=10,
                          values=[''], state='readonly')
        cb.pack(side='left', padx=(2, 10))
        cb.bind('<<ComboboxSelected>>', lambda _e: self.refresh_table())
        self.plat_cb = cb

        ttk.Label(bar, text='分类:').pack(side='left')
        cb2 = ttk.Combobox(bar, textvariable=self.cat_filter, width=14,
                           values=[''] + cat_values, state='readonly')
        cb2.pack(side='left', padx=(2, 10))
        cb2.bind('<<ComboboxSelected>>', lambda _e: self.refresh_table())
        self.cat_cb = cb2

        ttk.Checkbutton(bar, text='仅显示有金手指', variable=self.only_cheat,
                        command=self.refresh_table).pack(side='left')
        ttk.Checkbutton(bar, text='仅显示缺金手指', variable=self.only_missing,
                        command=self.refresh_table).pack(side='left',
                                                         padx=(8, 0))
        ttk.Button(bar, text='清空筛选', command=self.clear_filters).pack(
            side='left', padx=(10, 0))
        return bar

    def _build_library_tab(self, parent):
        self._filters_bar(parent, [])

        wrap = ttk.Frame(parent)
        wrap.pack(fill='both', expand=True)

        cols = ('name', 'name_cn', 'platform', 'category', 'size',
                'crc', 'cheats', 'internal', 'bios')
        tv = ttk.Treeview(wrap, columns=cols, show=('tree', 'headings'),
                          height=16)
        heads = {
            'name': '名称', 'name_cn': '中文名',
            'platform': '平台', 'category': '分类', 'size': '大小',
            'crc': 'CRC32', 'cheats': '金手指',
            'internal': '内部标题/原名', 'bios': '依赖 BIOS',
        }
        widths = {'name': 200, 'name_cn': 200, 'platform': 70,
                  'category': 90, 'size': 90, 'crc': 90, 'cheats': 66,
                  'internal': 200, 'bios': 150}
        for c in cols:
            tv.heading(c, text=heads[c],
                       command=lambda _c=c: self._sort_by(tv, _c))
            tv.column(c, width=widths[c],
                      anchor='w' if c in ('name', 'name_cn', 'internal', 'bios',
                                          'category') else 'center')
        # 图标列复用树列 #0(ttk 的 image 只能挂在 #0 上)
        tv.heading('#0', text='图标')
        tv.column('#0', width=34, anchor='center', stretch=False)
        vsb = ttk.Scrollbar(wrap, orient='vertical', command=tv.yview)
        tv.configure(yscrollcommand=vsb.set)
        vsb.pack(side='right', fill='y')
        tv.pack(side='left', fill='both', expand=True)
        self._apply_row_tags(tv)
        tv.bind('<Double-1>', lambda _e: self.show_game_detail())
        self.tv_games = tv
        self._sort_col = {'name': False}

        # 详情(选中游戏的金手指)
        det = ttk.LabelFrame(parent, text=' 选中游戏的金手指 ', padding=6)
        det.pack(fill='both', expand=False, pady=(6, 0))
        cols2 = ('cname', 'ccode')
        tv2 = ttk.Treeview(det, columns=cols2, show='headings', height=6)
        tv2.heading('cname', text='金手指名称')
        tv2.heading('ccode', text='命令 / 代码')
        tv2.column('cname', width=340, anchor='w')
        tv2.column('ccode', width=760, anchor='w')
        sb2 = ttk.Scrollbar(det, orient='vertical', command=tv2.yview)
        tv2.configure(yscrollcommand=sb2.set)
        sb2.pack(side='right', fill='y')
        tv2.pack(fill='x')
        self.tv_game_cheats = tv2
        tv.bind('<<TreeviewSelect>>', self._on_game_select)

    def _build_cheat_tab(self, parent):
        bar = ttk.Frame(parent, padding=(0, 6))
        bar.pack(fill='x')
        ttk.Label(bar, text='🔍').pack(side='left')
        self.cheat_query = tk.StringVar()
        e = ttk.Entry(bar, textvariable=self.cheat_query, width=30)
        e.pack(side='left', padx=(2, 0))
        self.cheat_query.trace_add('write', lambda *_: self.refresh_cheat_tab())
        ttk.Button(bar, text='重新关联金手指', command=self.resync_cheats).pack(
            side='right')

        wrap = ttk.Frame(parent)
        wrap.pack(fill='both', expand=True)
        cols = ('game', 'platform', 'count', 'file')
        tv = ttk.Treeview(wrap, columns=cols, show='headings')
        for c, t, w in (('game', '游戏', 260), ('platform', '平台', 80),
                        ('count', '命令数', 80), ('file', '文件', 420)):
            tv.heading(c, text=t)
            tv.column(c, width=w, anchor='w')
        vsb = ttk.Scrollbar(wrap, orient='vertical', command=tv.yview)
        tv.configure(yscrollcommand=vsb.set)
        vsb.pack(side='right', fill='y')
        tv.pack(side='left', fill='both', expand=True)
        self._apply_row_tags(tv)
        tv.tag_configure('orphan', foreground=C['warn'], background=C['warn_bg'])
        self.tv_cheats = tv
        tv.bind('<<TreeviewSelect>>', self._on_cheat_select)

        det = ttk.LabelFrame(parent, text=' 金手指命令 —— 支持编辑 / 新增 / 删除 (保存后同步到手机)',
                              padding=6)
        det.pack(fill='both', expand=True, pady=(6, 0))
        bb = ttk.Frame(det)
        bb.pack(fill='x')
        ttk.Button(bb, text='新增命令', style='Accent.TButton',
                   command=self.cheat_add).pack(side='left')
        ttk.Button(bb, text='编辑命令', command=self.cheat_edit).pack(
            side='left', padx=(6, 0))
        ttk.Button(bb, text='删除命令', command=self.cheat_delete).pack(
            side='left', padx=(6, 0))
        ttk.Button(bb, text='保存修改', command=self.cheat_save).pack(
            side='left', padx=(6, 0))
        cols2 = ('cname', 'ccode')
        tv2 = ttk.Treeview(det, columns=cols2, show='headings')
        tv2.heading('cname', text='名称')
        tv2.heading('ccode', text='命令 / 代码')
        tv2.column('cname', width=360, anchor='w')
        tv2.column('ccode', width=760, anchor='w')
        sb2 = ttk.Scrollbar(det, orient='vertical', command=tv2.yview)
        tv2.configure(yscrollcommand=sb2.set)
        sb2.pack(side='right', fill='y')
        tv2.pack(fill='both', expand=True)
        self.tv_cheat_cmds = tv2

    def _build_bios_tab(self, parent):
        bar = ttk.Frame(parent, padding=(0, 6))
        bar.pack(fill='x')
        ttk.Label(bar, text='BIOS(系统文件) —— 街机核心启动时必需, 与游戏本体分离'
                  ).pack(side='left')
        wrap = ttk.Frame(parent)
        wrap.pack(fill='both', expand=True)
        cols = ('name', 'size', 'desc', 'path')
        tv = ttk.Treeview(wrap, columns=cols, show='headings')
        for c, t, w in (('name', '文件名', 160), ('size', '大小', 110),
                        ('desc', '说明', 240), ('path', '路径', 620)):
            tv.heading(c, text=t)
            tv.column(c, width=w, anchor='w')
        vsb = ttk.Scrollbar(wrap, orient='vertical', command=tv.yview)
        tv.configure(yscrollcommand=vsb.set)
        vsb.pack(side='right', fill='y')
        tv.pack(side='left', fill='both', expand=True)
        self.tv_bios = tv

    def _build_report_tab(self, parent):
        self.report_text = tk.Text(parent, wrap='word', height=20,
                                   font=('Consolas', 10))
        vsb = ttk.Scrollbar(parent, orient='vertical',
                            command=self.report_text.yview)
        self.report_text.configure(yscrollcommand=vsb.set)
        vsb.pack(side='right', fill='y')
        self.report_text.pack(fill='both', expand=True, padx=4, pady=4)
        t = self.report_text
        t.configure(bg=C['panel'], fg=C['ink'], insertbackground=C['ink'],
                    relief='flat', padx=8, pady=8)
        t.tag_configure('h', font=('Microsoft YaHei UI', 10, 'bold'),
                        foreground=C['brand'])
        t.tag_configure('ok', foreground=C['ok'])
        t.tag_configure('bad', foreground=C['bad'])
        t.tag_configure('warn', foreground=C['warn'])
        t.tag_configure('muted', foreground=C['muted'])
        t.tag_configure('key', foreground=C['ink'],
                        font=('Microsoft YaHei UI', 9, 'bold'))
        for plat, fg in PLATFORM_COLOR.items():
            t.tag_configure('plat_' + (plat or 'none'), foreground=fg)
        t.configure(state='disabled')

    def _build_status(self):
        b = ttk.Frame(self, padding=(10, 4))
        b.pack(fill='x')
        ttk.Label(b, textvariable=self.status).pack(side='left')
        self.pb = ttk.Progressbar(b, mode='determinate', length=220)
        self.pb.pack(side='right')
        ttk.Separator(self).pack(fill='x')

    # ------------------------------------------------- 小工具: 卡片/日志
    def _hint(self, parent, text, kind='info'):
        fg, bg = {'info': (C['info'], C['info_bg']),
                  'warn': (C['warn'], C['warn_bg']),
                  'ok': (C['ok'], C['ok_bg']),
                  'bad': (C['bad'], C['bad_bg'])}.get(kind,
                                                      (C['info'], C['info_bg']))
        f = tk.Frame(parent, bg=bg)
        f.pack(fill='x', padx=2, pady=(6, 4))
        tk.Label(f, text='  ' + text + '  ', bg=bg, fg=fg, justify='left',
                 anchor='w', font=('Microsoft YaHei UI', 8),
                 wraplength=1100).pack(fill='x', pady=3)
        return f

    def _logbox(self, parent, height=8):
        f = ttk.Frame(parent)
        f.pack(fill='both', expand=True, pady=(6, 0))
        t = tk.Text(f, wrap='word', height=height, font=('Consolas', 9),
                    bg='#0f172a', fg='#d5e2f0', relief='flat', padx=8, pady=6,
                    insertbackground='#d5e2f0')
        t.tag_configure('ok', foreground='#4ade80')
        t.tag_configure('bad', foreground='#f87171')
        t.tag_configure('warn', foreground='#fbbf24')
        t.tag_configure('dim', foreground='#8fa3bf')
        sb = ttk.Scrollbar(f, orient='vertical', command=t.yview)
        t.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y')
        t.pack(fill='both', expand=True)
        t.configure(state='disabled')
        return t

    def _log(self, widget, text, tag=None):
        def _do():
            widget.configure(state='normal')
            widget.insert('end', text + '\n', tag)
            widget.see('end')
            widget.configure(state='disabled')
        if widget is None:
            return
        try:
            self.after(0, _do)
        except Exception:
            pass

    def _ui(self, fn):
        """从工作线程安全地回到 UI 线程。"""
        try:
            self.after(0, fn)
        except Exception:
            pass

    # ------------------------------------------------------- 页签: 联网检索
    def _build_online_tab(self, parent):
        self._hint(parent,
                   '为「缺金手指」的 ROM 上网检索并自动适配: 数据来自 '
                   'libretro/libretro-database 的 cht/ 目录。匹配采用'
                   '「归一化名称 → 前缀 → 相似度」三级打分, 低于阈值的'
                   '一律放弃; 同一个在线文件被多个 ROM 争抢时全部放弃。'
                   '结果写入 chats/<游戏名>.cht 与 chats/cheats.json, '
                   '可一键撤销。', 'info')

        bar = ttk.Frame(parent, padding=(0, 6))
        bar.pack(fill='x')
        ttk.Button(bar, text='一键检索并适配', style='Accent.TButton',
                   command=self.online_fetch).pack(side='left')
        ttk.Button(bar, text='停止', command=self.online_stop_fetch).pack(
            side='left', padx=(6, 0))
        ttk.Button(bar, text='撤销联网适配', command=self.online_undo).pack(
            side='left', padx=(6, 0))

        ttk.Label(bar, text='   平台:').pack(side='left')
        self.online_plat = tk.StringVar(value='')
        cb = ttk.Combobox(bar, textvariable=self.online_plat, width=10,
                          values=['', 'gba', 'nes', 'neogeo', 'cps1', 'cps2'],
                          state='readonly')
        cb.pack(side='left')
        ttk.Label(bar, text='  置信度 ≥').pack(side='left')
        self.online_score = tk.IntVar(value=int(online_cheats.SCORE_AUTO))
        ttk.Spinbox(bar, from_=60, to=100, width=5,
                    textvariable=self.online_score).pack(side='left')
        self.online_only_missing = tk.BooleanVar(value=True)
        ttk.Checkbutton(bar, text='只处理缺失的',
                        variable=self.online_only_missing).pack(side='left',
                                                                padx=(10, 0))
        self.online_progress = ttk.Progressbar(bar, mode='determinate',
                                               length=180)
        self.online_progress.pack(side='right')

        wrap = ttk.Frame(parent)
        wrap.pack(fill='both', expand=True)
        cols = ('game', 'platform', 'state', 'detail')
        tv = ttk.Treeview(wrap, columns=cols, show='headings', height=12)
        for c, t, w in (('game', '游戏', 260), ('platform', '平台', 80),
                        ('state', '状态', 90), ('detail', '来源 / 说明', 520)):
            tv.heading(c, text=t)
            tv.column(c, width=w, anchor='w' if c in ('game', 'detail') else 'center')
        vsb = ttk.Scrollbar(wrap, orient='vertical', command=tv.yview)
        tv.configure(yscrollcommand=vsb.set)
        vsb.pack(side='right', fill='y')
        tv.pack(side='left', fill='both', expand=True)
        tv.tag_configure('ok', foreground=C['ok'], background=C['ok_bg'])
        tv.tag_configure('skip', foreground=C['muted'])
        tv.tag_configure('fail', foreground=C['bad'], background=C['bad_bg'])
        tv.tag_configure('wait', foreground=C['warn'])
        self.tv_online = tv

        self.online_log = self._logbox(parent, height=8)

    def online_fetch(self):
        if getattr(self, '_online_running', False):
            messagebox.showinfo('正在检索', '上一次检索还没有结束。')
            return
        root = self.root_dir.get()
        if not os.path.isdir(root):
            messagebox.showwarning('目录无效', '请先选择有效的根目录。')
            return
        want_plat = self.online_plat.get()
        if self.online_only_missing.get():
            games = [g for g in self.games if not g['cheats']]
        else:
            games = list(self.games)
        if want_plat:
            games = [g for g in games if g['platform'] == want_plat]
        if not games:
            messagebox.showinfo('没有目标', '当前没有需要检索的游戏。')
            return

        self._online_running = True
        self._online_stop = threading.Event()
        tv = self.tv_online
        tv.delete(*tv.get_children())
        for g in games:
            tv.insert('', 'end', iid=g['path'], tags=('wait',),
                      values=(g['stem'],
                              PLATFORM_LABEL.get(g['platform'], g['platform']),
                              '排队', ''))
        self.online_progress['maximum'] = len(games)
        self.online_progress['value'] = 0
        self.status.set('联网检索: %d 个游戏' % len(games))

        score = float(self.online_score.get())
        index = online_cheats.ChtIndex(
            log=lambda s: self._log(self.online_log, '· ' + s, 'dim'))
        stop = self._online_stop

        def progress(done, total, game, state, detail):
            tag = {'ok': 'ok', 'failed': 'fail'}.get(state, 'skip')
            label = {'ok': '已适配', 'failed': '失败'}.get(state, '跳过')
            self._ui(lambda: self._online_row(game, done, tag, label, detail))

        def worker():
            try:
                res = online_cheats.run_batch(
                    root, games, index, on_progress=progress,
                    on_log=lambda s: self._log(self.online_log, s),
                    min_score=score, stop=stop)
                summary = res.as_dict()
                self._ui(lambda: self._online_done(summary))
            except Exception as ex:  # noqa: BLE001
                self._ui(lambda: self._online_done(None, str(ex)))

        threading.Thread(target=worker, daemon=True).start()

    def _online_row(self, game, done, tag, label, detail):
        tv = self.tv_online
        iid = game.get('path', '')
        if tv.exists(iid):
            tv.set(iid, 'state', label)
            tv.set(iid, 'detail', detail)
            tv.item(iid, tags=(tag,))
        self.online_progress['value'] = done
        self.status.set('联网检索 %d: %s' % (done, label))

    def _online_done(self, summary, err=None):
        self._online_running = False
        if err:
            self._log(self.online_log, '✘ ' + err, 'bad')
            self.status.set('联网检索失败')
            return
        n = summary['ok']
        self._log(self.online_log,
                  '完成: 适配 %d, 跳过 %d, 失败 %d'
                  % (n, summary['skipped'], summary['failed']),
                  'ok' if n else 'warn')
        self.status.set('联网检索完成: 新增 %d' % n)
        if n:
            self.scan(rescan=False)

    def online_stop_fetch(self):
        ev = getattr(self, '_online_stop', None)
        if ev:
            ev.set()
            self._log(self.online_log, '已请求停止…', 'warn')

    def online_undo(self):
        root = self.root_dir.get()
        n = online_cheats.load_online_report(root)
        if not n:
            messagebox.showinfo('撤销', '没有联网适配记录。')
            return
        if not messagebox.askyesno(
                '撤销联网适配',
                '将删除 %d 个联网下载的 .cht 文件及其 cheats.json 条目, '
                '不会影响本地原有的金手指。继续?' % len(n)):
            return
        k = online_cheats.undo_online(root)
        self._log(self.online_log, '已撤销 %d 项联网适配' % k, 'warn')
        self.scan(rescan=False)

    # ------------------------------------------------------- 页签: 手机同步
    def _build_phone_tab(self, parent):
        self._hint(parent,
                   '把本地库送到手机上的趣玩匣 App。两种方式任选: '
                   '① USB 直推 —— 需要 adb 与 debuggable 的调试包; '
                   '② 局域网 —— 启动本机「伙伴」服务, 用手机「我的 → 发现伙伴」'
                   '配对后由手机主动拉取(release 包也能用)。', 'info')

        sub = ttk.Notebook(parent)
        sub.pack(fill='both', expand=True, pady=(4, 0))
        self._build_usb_panel(sub)
        self._build_lan_panel(sub)
        sub.bind('<<NotebookTabChanged>>', self._phone_tab_changed)

    # ---- USB(adb) ----
    def _build_usb_panel(self, nb):
        p = ttk.Frame(nb, padding=8)
        nb.add(p, text=' USB 直推 (adb) ')

        row = ttk.Frame(p)
        row.pack(fill='x')
        ttk.Label(row, text='adb:').pack(side='left')
        self.adb_path = tk.StringVar(value=phone_sync.find_adb())
        ttk.Entry(row, textvariable=self.adb_path, width=58).pack(
            side='left', padx=(4, 4))
        ttk.Button(row, text='浏览…', command=self._pick_adb).pack(side='left')
        ttk.Button(row, text='刷新设备', command=self.adb_refresh).pack(
            side='left', padx=(6, 0))
        self.usb_state = tk.StringVar(value='未连接')
        tk.Label(row, textvariable=self.usb_state, bg=C['bg'],
                 fg=C['muted'], font=('Microsoft YaHei UI', 9, 'bold')
                 ).pack(side='left', padx=(12, 0))

        row2 = ttk.Frame(p, padding=(0, 8, 0, 0))
        row2.pack(fill='x')
        ttk.Label(row2, text='设备:').pack(side='left')
        self.dev_var = tk.StringVar()
        self.dev_cb = ttk.Combobox(row2, textvariable=self.dev_var, width=34,
                                   state='readonly')
        self.dev_cb.pack(side='left', padx=(4, 10))
        self.dev_cb.bind('<<ComboboxSelected>>',
                         lambda _e: self.adb_probe_device())

        self.push_rom = tk.BooleanVar(value=True)
        self.push_cheat = tk.BooleanVar(value=True)
        self.push_bios = tk.BooleanVar(value=True)
        self.overwrite_cheat = tk.BooleanVar(value=False)
        ttk.Checkbutton(row2, text='ROM', variable=self.push_rom).pack(
            side='left')
        ttk.Checkbutton(row2, text='金手指', variable=self.push_cheat).pack(
            side='left', padx=(8, 0))
        ttk.Checkbutton(row2, text='BIOS', variable=self.push_bios).pack(
            side='left', padx=(8, 0))
        ttk.Checkbutton(row2, text='覆盖同名金手指',
                        variable=self.overwrite_cheat).pack(side='left',
                                                            padx=(8, 0))

        row3 = ttk.Frame(p, padding=(0, 8, 0, 0))
        row3.pack(fill='x')
        ttk.Button(row3, text='推送到手机', style='Accent.TButton',
                   command=self.adb_push).pack(side='left')
        ttk.Button(row3, text='启动手机 App',
                   command=self.adb_launch).pack(side='left', padx=(6, 0))
        ttk.Button(row3, text='修复中文名',
                   command=self.adb_repair).pack(side='left', padx=(6, 0))
        self.push_scope = tk.StringVar(value='(按「游戏库」页当前筛选结果)')
        ttk.Label(row3, textvariable=self.push_scope).pack(side='left',
                                                           padx=(12, 0))
        self._hint(p, '推送范围 = 「游戏库」页当前的筛选结果(可先用平台/搜索'
                      '筛选)。已存在于手机的 ROM 会按 CRC32 自动跳过; '
                      'rom_index.json 写入前会先备份为 .bak。\n'
                      '「修复中文名」: 旧版工具曾把中文名替换成下划线(如 __.gba), '
                      '按 CRC32 对照本地库把手机上的名字/文件名恢复为真实中文名。',
                  'warn')
        self.usb_log = self._logbox(p, height=10)

    def _pick_adb(self):
        p = filedialog.askopenfilename(
            title='选择 adb', filetypes=[('adb', 'adb.exe'), ('所有', '*.*')])
        if p:
            self.adb_path.set(p)
            self.adb_refresh()

    def _adb(self) -> phone_sync.Adb:
        return phone_sync.Adb(self.adb_path.get().strip())

    def adb_refresh(self):
        adb = self._adb()
        if not adb.ok():
            self.usb_state.set('未找到 adb')
            self._log(self.usb_log, '未找到 adb: %s' % self.adb_path.get(),
                      'bad')
            self.dev_cb['values'] = []
            return
        devs = adb.devices()
        vals = ['%s  (%s)' % (d['serial'], d['model'] or d['state'])
                for d in devs]
        self.dev_cb['values'] = vals
        if vals and not self.dev_var.get():
            self.dev_cb.current(0)
        self._log(self.usb_log, '发现 %d 台设备' % len(devs),
                  'ok' if devs else 'warn')
        if devs:
            self.adb_probe_device()

    def adb_probe_device(self):
        serial = (self.dev_var.get() or '').split()[0]
        if not serial:
            return

        def work():
            info = self._adb_probe(serial)
            self._ui(lambda: self._adb_probe_ui(info))

        threading.Thread(target=work, daemon=True).start()

    def _adb_probe(self, serial):
        try:
            return phone_sync.PhoneSync(self._adb(), serial).probe()
        except Exception as ex:  # noqa: BLE001
            return {'ok': False, 'msg': str(ex)}

    def _adb_probe_ui(self, info):
        if info.get('ok'):
            self.usb_state.set('已连接 · 手机 %d 个游戏 / %d 个 BIOS'
                               % (info.get('roms', 0), info.get('bios', 0)))
            self._log(self.usb_log, '✔ %s' % info.get('msg', ''), 'ok')
        else:
            self.usb_state.set('不可用')
            self._log(self.usb_log, '✘ %s' % info.get('msg', ''), 'bad')

    def adb_launch(self):
        serial = (self.dev_var.get() or '').split()[0]
        if not serial:
            return
        ok = phone_sync.PhoneSync(self._adb(), serial).launch_app()
        self._log(self.usb_log, '启动 App: %s' % ('成功' if ok else '失败'),
                  'ok' if ok else 'bad')

    def adb_push(self):
        serial = (self.dev_var.get() or '').split()[0]
        if not serial:
            messagebox.showwarning('未选择设备', '请先刷新并选择一台设备。')
            return
        games = self._visible_games()
        if not games:
            messagebox.showinfo('没有内容', '当前筛选结果为空。')
            return
        root = self.root_dir.get()
        by_crc = {}
        if self.push_cheat.get():
            cj = os.path.join(root, 'chats', 'cheats.json')
            try:
                with open(cj, 'r', encoding='utf-8') as f:
                    by_crc = (json.load(f) or {}).get('byCrc', {})
            except Exception:
                by_crc = {g['crc']: g['cheats'] for g in games
                          if g.get('crc') and g.get('cheats')}
            sel = {g['crc'] for g in games if g.get('crc')}
            by_crc = {k: v for k, v in by_crc.items() if k in sel}
        plan = phone_sync.build_plan(
            games if self.push_rom.get() else [],
            self.bios if self.push_bios.get() else [], by_crc)
        if not plan['items'] and not plan['bios'] and not plan['cheats']:
            messagebox.showinfo('没有内容', '没有任何要推送的项目。')
            return

        self.status.set('推送中…')
        overwrite = self.overwrite_cheat.get()

        def work():
            try:
                sync = phone_sync.PhoneSync(self._adb(), serial)
                res = sync.push(
                    plan, overwrite_cheats=overwrite,
                    on_log=lambda s: self._log(self.usb_log, '· ' + s, 'dim'),
                    on_progress=lambda i, n, name: self._ui(
                        lambda: self.status.set('推送 %d/%d: %s' % (i, n, name))))
                self._ui(lambda: self._adb_push_done(res))
            except Exception as ex:  # noqa: BLE001
                self._ui(lambda: self._adb_push_done(None, str(ex)))

        threading.Thread(target=work, daemon=True).start()

    def _adb_push_done(self, res, err=None):
        if err:
            self._log(self.usb_log, '✘ %s' % err, 'bad')
            self.status.set('推送失败')
            return
        self._log(self.usb_log, '✔ ' + res.as_text(), 'ok')
        self.status.set('推送完成: ' + res.as_text())

    def adb_repair(self):
        serial = (self.dev_var.get() or '').split()[0]
        if not serial:
            messagebox.showwarning('未选择设备', '请先刷新并选择一台设备。')
            return
        games = self._visible_games()
        if not games:
            messagebox.showinfo('没有内容', '当前筛选结果为空。')
            return
        if not messagebox.askyesno(
                '修复中文名',
                '将按 CRC32 把手机索引里的游戏名/文件名恢复成本地库的真实中文名'
                '(旧版工具曾把中文替换成下划线)。会先备份 rom_index.json 为 .bak。\n'
                '继续？'):
            return
        self.status.set('修复中…')

        def work():
            try:
                sync = phone_sync.PhoneSync(self._adb(), serial)
                res = sync.repair_names(
                    games, on_log=lambda s: self._log(self.usb_log, '· ' + s,
                                                      'dim'))
                self._ui(lambda: self._adb_repair_done(res))
            except Exception as ex:  # noqa: BLE001
                self._ui(lambda: self._adb_repair_done(None, str(ex)))

        threading.Thread(target=work, daemon=True).start()

    def _adb_repair_done(self, res, err=None):
        if err:
            self._log(self.usb_log, '✘ %s' % err, 'bad')
            self.status.set('修复失败')
            return
        self._log(self.usb_log, '✔ ' + res.as_text(), 'ok')
        self.status.set('修复完成: ' + res.as_text())

    # ---- 局域网(伙伴) ----
    def _build_lan_panel(self, nb):
        p = ttk.Frame(nb, padding=8)
        nb.add(p, text=' 局域网 (手机来拉) ')

        row = ttk.Frame(p)
        row.pack(fill='x')
        self.lan_btn = ttk.Button(row, text='启动服务', style='Accent.TButton',
                                  command=self.lan_toggle)
        self.lan_btn.pack(side='left')
        self.lan_addr = tk.StringVar(value='未启动')
        tk.Label(row, textvariable=self.lan_addr, bg=C['bg'], fg=C['brand'],
                 font=('Consolas', 10, 'bold')).pack(side='left', padx=(12, 0))
        self.lan_poll = ttk.Button(row, text='检查配对请求',
                                   command=self.lan_check_pairs)
        self.lan_poll.pack(side='right')

        self._hint(p, '使用方法: 手机与电脑在同一 Wi-Fi → 手机上打开 '
                      '「我的 → 发现伙伴」→ 列表里应出现本机的名字 → 点配对 → '
                      '手机上会显示 6 位码, 这里点「检查配对请求」核对后确认 → '
                      '配对成功后手机即可浏览并导入本机游戏库。', 'warn')

        cols = ('name', 'code', 'id')
        f = ttk.LabelFrame(p, text=' 待确认的配对请求 ', padding=6)
        f.pack(fill='x', pady=(6, 0))
        tv = ttk.Treeview(f, columns=cols, show='headings', height=4)
        for c, t, w in (('name', '设备名', 220), ('code', '配对码', 100),
                        ('id', 'pairId', 300)):
            tv.heading(c, text=t)
            tv.column(c, width=w, anchor='w')
        tv.pack(fill='x')
        tv.tag_configure('wait', foreground=C['warn'], background=C['warn_bg'])
        self.tv_pairs = tv
        br = ttk.Frame(f, padding=(0, 6, 0, 0))
        br.pack(fill='x')
        ttk.Button(br, text='确认配对', command=self.lan_confirm).pack(
            side='left')
        ttk.Button(br, text='拒绝', command=self.lan_reject).pack(
            side='left', padx=(6, 0))

        f2 = ttk.LabelFrame(p, text=' 已配对的设备 ', padding=6)
        f2.pack(fill='x', pady=(8, 0))
        tv2 = ttk.Treeview(f2, columns=('name', 'ip', 'at'),
                           show='headings', height=4)
        for c, t, w in (('name', '设备名', 220), ('ip', '上次 IP', 160),
                        ('at', '配对时间', 200)):
            tv2.heading(c, text=t)
            tv2.column(c, width=w, anchor='w')
        tv2.pack(fill='x')
        tv2.tag_configure('ok', foreground=C['ok'], background=C['ok_bg'])
        self.tv_devs = tv2
        ttk.Button(f2, text='忘记所选', command=self.lan_forget).pack(
            anchor='w', pady=(6, 0))

        self.lan_log = self._logbox(p, height=8)

    def lan_toggle(self):
        host = getattr(self, '_peer', None)
        if host and host.running:
            host.stop()
            self._peer = None
            self.lan_btn.configure(text='启动服务')
            self.lan_addr.set('未启动')
            self._log(self.lan_log, '服务已停止', 'dim')
            return
        root = self.root_dir.get()
        games = self.games
        host = peer_host.PeerHost(
            library=peer_host.build_library(
                games, self.bios, self.cheat_by_crc or {}),
            log=lambda s: self._log(self.lan_log, '· ' + s, 'dim'))
        try:
            port = host.start()
        except Exception as ex:  # noqa: BLE001
            messagebox.showerror('启动失败', str(ex))
            return
        self._peer = host
        self.lan_btn.configure(text='停止服务')
        self.lan_addr.set('%s:%d' % (peer_host.local_ip(), port))
        self._log(self.lan_log, '服务已启动, 等待手机发现…', 'ok')
        self.lan_refresh_devices()
        # 自动轮询配对请求, 这样手机发起配对后这里会即时出现, 用户点
        # 「确认配对」即可; 否则手机会在长轮询超时后认为配对失败。
        self._lan_poll()

    def lan_check_pairs(self):
        host = getattr(self, '_peer', None)
        if not host or not host.running:
            return
        tv = self.tv_pairs
        keep = tv.selection()            # 保留用户已选(避免轮询刷新丢选)
        tv.delete(*tv.get_children())
        for r in host.pending_pairs():
            tv.insert('', 'end', iid=r.pair_id, tags=('wait',),
                      values=(r.name, r.code, r.pair_id))
        for k in keep:
            if tv.exists(k):
                tv.selection_add(k)
        n = len(tv.get_children())
        self._log(self.lan_log, '待确认请求: %d' % n, 'warn' if n else 'dim')

    def _selected_pair(self):
        tv = self.tv_pairs
        sel = tv.selection()
        return sel[0] if sel else None

    def _lan_poll(self):
        host = getattr(self, '_peer', None)
        if not host or not host.running:
            return
        self.lan_check_pairs()
        self.after(1500, self._lan_poll)

    def lan_confirm(self):
        host = getattr(self, '_peer', None)
        pid = self._selected_pair()
        if not host or not pid:
            return
        host.confirm_pair(pid)
        self._log(self.lan_log, '已确认配对: %s' % pid, 'ok')
        self.lan_check_pairs()
        self.lan_refresh_devices()

    def lan_reject(self):
        host = getattr(self, '_peer', None)
        pid = self._selected_pair()
        if not host or not pid:
            return
        host.reject_pair(pid)
        self._log(self.lan_log, '已拒绝: %s' % pid, 'warn')
        self.lan_check_pairs()

    def lan_forget(self):
        host = getattr(self, '_peer', None)
        tv = self.tv_devs
        sel = tv.selection()
        if not host or not sel:
            return
        host.forget(sel[0])
        self.lan_refresh_devices()

    def lan_refresh_devices(self):
        host = getattr(self, '_peer', None)
        tv = self.tv_devs
        tv.delete(*tv.get_children())
        if not host:
            return
        for did, d in host.devices.items():
            tv.insert('', 'end', iid=did, tags=('ok',),
                      values=(d.get('name', ''), d.get('lastIp', ''),
                              d.get('pairedAt', '')))

    def _phone_tab_changed(self, _e):
        if self.dev_cb['values'] == [] or not self.dev_var.get():
            self.after(50, self.adb_refresh)
        self.push_scope.set('推送范围: %d 个(游戏库页当前筛选结果)'
                            % len(self._visible_games()))

    def _bind_keys(self):
        self.bind('<F5>', lambda _e: self.scan(rescan=True))
        self.bind('<Control-f>',
                  lambda _e: self.nb.select(0) or self.focus())

    # ----------------------------------------------------------- 扫描
    def choose_root(self):
        d = filedialog.askdirectory(initialdir=self.root_dir.get() or '.')
        if d:
            self.root_dir.set(d)
            self.scan(rescan=True)

    def scan(self, rescan: bool):
        if self._scanning:
            return
        root = self.root_dir.get()
        if not root or not os.path.isdir(root):
            messagebox.showwarning('目录无效', '请选择有效的根目录。')
            return
        self._scanning = True
        self._warn_msg = ''   # 每次扫描重置, 避免上一次的提示残留
        self.status.set('扫描中: 枚举文件…')
        self.pb['value'] = 0
        t = threading.Thread(target=self._scan_worker,
                             args=(root, rescan), daemon=True)
        t.start()
        self.after(80, self._pump)

    def _scan_worker(self, root: str, rescan: bool):
        try:
            games, bios, orphans = self._collect(root)
            self._q.put(('phase1', games, bios, orphans))
            # 阶段2: CRC(带缓存)
            todo = [g for g in games
                    if rescan or not g.get('crc')]
            total = len(todo)
            for i, g in enumerate(todo):
                key = (g['path'], g['size'], g.get('mtime', 0))
                c = self.crc_cache.get(key)
                if not c:
                    c = fast_crc32_file(g['path'])
                    self.crc_cache[key] = c
                g['crc'] = c
                if i % 8 == 0 or i + 1 == total:
                    self._q.put(('progress', i + 1, total))
            # 阶段3: 按 CRC 关联 GamePouch 原生 cheats.json
            cj = os.path.join(root, 'chats', 'cheats.json')
            if os.path.isfile(cj):
                try:
                    with open(cj, 'r', encoding='utf-8') as f:
                        j = json.load(f)
                    self.cheat_by_crc = (j.get('byCrc') or {})
                except Exception:
                    self.cheat_by_crc = {}
            for g in games:
                if not g.get('cheats') and g.get('crc') in self.cheat_by_crc:
                    g['cheats'] = self.cheat_by_crc[g['crc']]
            # 关联内置元数据索引的中文名与封面(按 CRC 优先, 平台+英文名 次之)
            if self.meta.available:
                self.meta.enrich(games)
            else:
                # 数据源缺失时明确告知, 不要静默留空让人以为功能坏了。
                # 索引随仓库分发在 tools/library/metadata/, 一般不会缺; 真缺了
                # 可用 GAMEPOUCH_META_DIR 指向别处的索引。
                self._q.put(('warn', '未找到游戏元数据索引(tools/library/metadata), '
                                     '中文名/封面列为空'))
            self._save_crc_cache()
            self._q.put(('done', len(games), len(bios)))
        except Exception as ex:  # noqa: BLE001
            self._q.put(('error', str(ex)))

    def _collect(self, root):
        """枚举 roms/、bios/、chats/。"""
        games, bios, orphans = [], [], []

        # --- ROM: 优先 roms/<子目录>, 否则整个根目录扁平扫描
        roms_root = os.path.join(root, 'roms')
        search_roots = []
        if os.path.isdir(roms_root):
            for sub in sorted(os.listdir(roms_root)):
                p = os.path.join(roms_root, sub)
                if os.path.isdir(p):
                    search_roots.append((p, sub))
            search_roots.append((roms_root, ''))
        else:
            search_roots.append((root, ''))

        seen = set()
        for base, sub in search_roots:
            for name in sorted(os.listdir(base)):
                if not name.lower().endswith(ROM_EXTS):
                    continue
                p = os.path.join(base, name)
                if not os.path.isfile(p) or p in seen:
                    continue
                seen.add(p)
                stem = os.path.splitext(name)[0]
                ext = os.path.splitext(name)[1].lower()
                plat = DIR_PLATFORM.get(sub.lower()) or EXT_PLATFORM.get(ext, '')
                if plat == 'arcade':
                    # 扁平 zip: 无法可靠区分 CPS/NeoGeo, 标为街机
                    plat = 'arcade'
                games.append({
                    'stem': stem, 'file': name,
                    'rel': os.path.relpath(p, root),
                    'platform': plat, 'category': sub or '未分类',
                    'size': os.path.getsize(p),
                    'mtime': int(os.path.getmtime(p)),
                    'crc': '', 'internal': '',
                    'cheats': [], 'cheat_file': '', 'path': p,
                })

        # GBA 内部标题(快速, 只读 16 字节)
        for g in games:
            if g['platform'] == 'gba':
                g['internal'] = gba_internal_title(g['path'])

        # --- 金手指: chats/<主干>.cht
        chats = os.path.join(root, 'chats')
        if os.path.isdir(chats):
            idx = {}
            for name in os.listdir(chats):
                if name.lower().endswith('.cht'):
                    idx[os.path.splitext(name)[0]] = os.path.join(chats, name)
            for g in games:
                cf = idx.get(g['stem'])
                if cf:
                    try:
                        with open(cf, 'r', encoding='utf-8', errors='replace') as f:
                            g['cheats'] = parse_cht_text(f.read())
                        g['cheat_file'] = cf
                    except Exception:
                        pass
            # 未关联到游戏的孤立金手指
            used = {g['stem'] for g in games if g['cheat_file']}
            od = os.path.join(chats, '_orphans')
            for k, v in idx.items():
                if k not in used:
                    try:
                        with open(v, 'r', encoding='utf-8', errors='replace') as f:
                            cs = parse_cht_text(f.read())
                    except Exception:
                        cs = []
                    orphans.append({'name': k, 'file': v, 'cheats': cs,
                                    'from': 'chats'})
            if os.path.isdir(od):
                for name in os.listdir(od):
                    if name.lower().endswith('.cht'):
                        p = os.path.join(od, name)
                        try:
                            with open(p, 'r', encoding='utf-8',
                                      errors='replace') as f:
                                cs = parse_cht_text(f.read())
                        except Exception:
                            cs = []
                        orphans.append({'name': os.path.splitext(name)[0],
                                        'file': p, 'cheats': cs,
                                        'from': '_orphans'})

        # --- BIOS: bios/ 目录
        for bdir in (os.path.join(root, 'bios'), os.path.join(root, 'system')):
            if not os.path.isdir(bdir):
                continue
            for name in sorted(os.listdir(bdir)):
                p = os.path.join(bdir, name)
                if not os.path.isfile(p):
                    continue
                if os.path.splitext(name)[1].lower() not in ('.zip', '.bin'):
                    continue
                bios.append({'name': name, 'size': os.path.getsize(p),
                             'path': p,
                             'desc': BIOS_DESC.get(name, '归拢的 BIOS/系统文件')})
        return games, bios, orphans

    def _pump(self):
        try:
            while True:
                msg = self._q.get_nowait()
                kind = msg[0]
                if kind == 'phase1':
                    _, games, bios, orphans = msg
                    self.games, self.bios, self.orphan_cheats = (games, bios,
                                                                 orphans)
                    self._after_phase1()
                elif kind == 'progress':
                    _, cur, tot = msg
                    self.pb['maximum'] = max(tot, 1)
                    self.pb['value'] = cur
                    self.status.set('扫描中: 计算 CRC32 %d/%d' % (cur, tot))
                elif kind == 'done':
                    self._scanning = False
                    self.pb['value'] = 0
                    self._after_phase1()
                    self.refresh_table()
                    self.refresh_cheat_tab()
                    self.refresh_bios_tab()
                    self.refresh_report()
                    n_cheat = sum(1 for g in self.games if g['cheats'])
                    tail = (' | %s' % self._warn_msg) if self._warn_msg else ''
                    self.status.set(
                        '完成: 游戏 %d (有金手指 %d) | BIOS %d | 孤立金手指 %d%s'
                        % (len(self.games), n_cheat, len(self.bios),
                           len(self.orphan_cheats), tail))
                    return
                elif kind == 'error':
                    self._scanning = False
                    self.status.set('扫描失败: %s' % msg[1])
                    return
                elif kind == 'warn':
                    # 非致命提示(如元数据索引缺失), 不打断扫描; 先累积, 由上面的
                    # 'done' 分支一并显示, 否则会被完成信息覆盖掉。
                    self._warn_msg = msg[1]
        except queue.Empty:
            pass
        self.after(120, self._pump)

    def _after_phase1(self):
        self._update_stats()
        plats = sorted({g['platform'] for g in self.games if g['platform']})
        self.plat_cb['values'] = [''] + [PLATFORM_LABEL.get(p, p)
                                         for p in plats]
        cats = sorted({g['category'] for g in self.games if g['category']})
        self.cat_cb['values'] = [''] + cats
        self.refresh_table()
        self.refresh_cheat_tab()
        self.refresh_bios_tab()
        self.refresh_report()

    # ----------------------------------------------------------- 表格刷新
    def _visible_games(self):
        q = self.query.get().strip().lower()
        pf = self.plat_filter.get()
        cf = self.cat_filter.get()
        out = []
        for g in self.games:
            if pf and PLATFORM_LABEL.get(g['platform'], g['platform']) != pf:
                continue
            if cf and g['category'] != cf:
                continue
            if self.only_cheat.get() and not g['cheats']:
                continue
            if self.only_missing.get() and g['cheats']:
                continue
            if q:
                hay = ('%s %s %s %s' % (g['stem'], g.get('name_cn') or '',
                                        g['internal'], g['category'])).lower()
                if q not in hay:
                    continue
            out.append(g)
        return out

    def refresh_table(self):
        tv = self.tv_games
        sel = tv.selection()
        prev = sel[0] if sel else None
        tv.delete(*tv.get_children())
        for g in self._visible_games():
            need = PLATFORM_BIOS.get(g['platform'], [])
            tags = (self.row_tags.get((g['platform'], bool(g['cheats'])), ''),)
            vals = (
                g['stem'],
                g.get('name_cn') or '—',
                PLATFORM_LABEL.get(g['platform'], g['platform']),
                g['category'],
                human_size(g['size']),
                g['crc'] or '…',
                len(g['cheats']) if g['cheats'] else '—',
                g['internal'] or '—',
                ', '.join(need) if need else '—',
            )
            img = self._load_icon(g.get('icon') or '')
            # 注意: image=None 会让 ttk 的 insert 解析错乱(见 TclError unknown option),
            # 因此无图标时绝不传 image。
            if img is not None:
                tv.insert('', 'end', iid=g['path'], tags=tags, image=img,
                          values=vals)
            else:
                tv.insert('', 'end', iid=g['path'], tags=tags, values=vals)
        if prev and tv.exists(prev):
            tv.selection_set(prev)

    def _load_icon(self, path: str):
        """读取封面图并缩成 28x28 缩略图(缓存)。失败时返回空(None)。"""
        if not path or not os.path.isfile(path):
            return None
        img = self._icon_imgs.get(path)
        if img is not None or path in self._icon_imgs:
            return img
        try:
            from PIL import Image, ImageTk
            im = Image.open(path).convert('RGBA').resize((28, 28),
                                                        Image.LANCZOS)
            img = ImageTk.PhotoImage(im)
        except Exception:
            img = None
        self._icon_imgs[path] = img
        return img

    def _sort_by(self, tv, col):
        key_map = {'name': lambda g: g['stem'].lower(),
                   'name_cn': lambda g: (g.get('name_cn') or '').lower(),
                   'platform': lambda g: g['platform'],
                   'category': lambda g: g['category'],
                   'size': lambda g: g['size'],
                   'crc': lambda g: g['crc'],
                   'cheats': lambda g: len(g['cheats']),
                   'internal': lambda g: g['internal'].lower(),
                   'bios': lambda g: g['platform']}
        if col in key_map:
            rev = self._sort_col.get(col, False)
            self.games.sort(key=key_map[col], reverse=rev)
            self._sort_col = {col: not rev}
            self.refresh_table()

    def _on_game_select(self, _e):
        tv = self.tv_games
        tv2 = self.tv_game_cheats
        tv2.delete(*tv2.get_children())
        sel = tv.selection()
        if not sel:
            return
        g = next((x for x in self.games if x['path'] == sel[0]), None)
        if not g:
            return
        for c in g['cheats']:
            tv2.insert('', 'end', values=(c.get('name', ''),
                                          (c.get('code') or '').replace('\n', ' ')))

    def refresh_cheat_tab(self):
        tv = self.tv_cheats
        tv.delete(*tv.get_children())
        q = getattr(self, 'cheat_query', None)
        qs = q.get().strip().lower() if q else ''
        for g in self.games:
            if not g['cheats']:
                continue
            if qs and qs not in ('%s %s' % (g['stem'], g['internal'])).lower():
                continue
            tv.insert('', 'end', iid='G:' + g['path'],
                      tags=(self.row_tags.get((g['platform'], True), ''),),
                      values=(
                          g['stem'],
                          PLATFORM_LABEL.get(g['platform'], g['platform']),
                          len(g['cheats']),
                          os.path.basename(g['cheat_file']) or '—'))
        for o in self.orphan_cheats:
            if qs and qs not in o['name'].lower():
                continue
            tv.insert('', 'end', iid='O:' + o['file'], tags=('orphan',),
                      values=(o['name'], '孤立', len(o['cheats']),
                              os.path.basename(o['file'])))

    def _on_cheat_select(self, _e):
        tv = self.tv_cheats
        tv2 = self.tv_cheat_cmds
        tv2.delete(*tv2.get_children())
        sel = tv.selection()
        if not sel:
            self.cur_cheat_items = None
            self.cur_cheat_target = None
            return
        iid = sel[0]
        if iid.startswith('G:'):
            g = next((x for x in self.games if x['path'] == iid[2:]), None)
            self.cur_cheat_items = g['cheats'] if g else None
            self.cur_cheat_target = ('G', g) if g else None
            self.cur_cheat_display = g.get('stem', '') if g else ''
        else:
            o = next((x for x in self.orphan_cheats
                      if x['file'] == iid[2:]), None)
            self.cur_cheat_items = o['cheats'] if o else None
            self.cur_cheat_target = ('O', o) if o else None
            self.cur_cheat_display = o.get('file', '') if o else ''
        self._refresh_cheat_cmds()

    def _refresh_cheat_cmds(self):
        tv2 = self.tv_cheat_cmds
        tv2.delete(*tv2.get_children())
        if not self.cur_cheat_items:
            stem = getattr(self, 'cur_cheat_display', '') or ''
            tv2.insert('', 'end', iid='hint',
                       values=('（该游戏未关联金手指）',
                               'chats/%s.cht 未找到且 cheats.json 无匹配'
                               % stem))
            return
        for i, c in enumerate(self.cur_cheat_items):
            tv2.insert('', 'end', iid=str(i),
                       values=(c.get('name', ''),
                               (c.get('code') or '').replace('\n', ' ')))

    # ------------------------------------------------- 金手指编辑
    def cheat_add(self):
        if not self.cur_cheat_items:
            messagebox.showinfo('请选择', '先在左侧选一个游戏(或孤立金手指)。')
            return
        self._edit_cheat_cmd(None)

    def cheat_edit(self):
        if not self.cur_cheat_items:
            return
        sel = self.tv_cheat_cmds.selection()
        if not sel:
            messagebox.showinfo('请选择', '先在右侧选中一条命令。')
            return
        self._edit_cheat_cmd(int(sel[0]))

    def cheat_delete(self):
        if not self.cur_cheat_items:
            return
        sel = self.tv_cheat_cmds.selection()
        if not sel:
            messagebox.showinfo('请选择', '先在右侧选中一条命令。')
            return
        idx = int(sel[0])
        del self.cur_cheat_items[idx]
        self._refresh_cheat_cmds()
        self._save_cheat_target()
        self.refresh_cheat_tab()
        self._log(self.status, '已删除 1 条命令', 'warn')

    def cheat_save(self):
        if not self.cur_cheat_target:
            messagebox.showinfo('请选择', '先选一个游戏再保存。')
            return
        self._save_cheat_target()
        messagebox.showinfo('已保存',
                            '金手指已写入 .cht 与 cheats.json, 手机端同步后会更新。')

    def _edit_cheat_cmd(self, idx):
        existing = self.cur_cheat_items[idx] if idx is not None else None
        dlg = CheatCmdDialog(self, existing)
        self.wait_window(dlg)
        if dlg.result is None:
            return
        if idx is None:
            self.cur_cheat_items.append(dlg.result)
        else:
            self.cur_cheat_items[idx] = dlg.result
        self._refresh_cheat_cmds()
        self._save_cheat_target()
        self.refresh_cheat_tab()

    def _save_cheat_target(self):
        """把当前金手指列表写回 .cht 与 cheats.json(byCrc)。"""
        root = self.root_dir.get()
        if not root:
            return
        chats = os.path.join(root, 'chats')
        os.makedirs(chats, exist_ok=True)
        items = self.cur_cheat_items
        if not items:
            return
        kind, target = self.cur_cheat_target
        if kind == 'G':
            g = target
            cf = g.get('cheat_file') or os.path.join(chats, g['stem'] + '.cht')
            with open(cf, 'w', encoding='utf-8') as f:
                f.write(to_cht_text(items))
            g['cheat_file'] = cf
            crc = str(g.get('crc') or '').upper()
            if crc:
                self._merge_cheats_json(chats, crc, items)
                self.cheat_by_crc[crc] = items
        else:  # 孤立金手指: 只回写 .cht
            o = target
            with open(o['file'], 'w', encoding='utf-8') as f:
                f.write(to_cht_text(items))

    def _merge_cheats_json(self, chats, crc, items):
        cj = os.path.join(chats, 'cheats.json')
        data = {'version': 1, 'byCrc': {}}
        if os.path.isfile(cj):
            try:
                with open(cj, 'r', encoding='utf-8') as f:
                    data = json.load(f) or data
                data.setdefault('byCrc', {})
            except Exception:
                pass
        data['byCrc'][crc] = items
        tmp = cj + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
        os.replace(tmp, cj)

    def refresh_bios_tab(self):
        tv = self.tv_bios
        tv.delete(*tv.get_children())
        tv.tag_configure('bios', foreground=C['warn'],
                         background=C['warn_bg'])
        for b in self.bios:
            tv.insert('', 'end', tags=('bios',),
                      values=(b['name'], human_size(b['size']),
                              b['desc'], b['path']))

    def refresh_report(self):
        t = self.report_text
        t.configure(state='normal')
        t.delete('1.0', 'end')
        total = len(self.games)
        with_cheat = [g for g in self.games if g['cheats']]
        n_cmd = sum(len(g['cheats']) for g in with_cheat)

        def line(s, tag=None):
            t.insert('end', s + '\n', tag)

        line('=' * 68)
        line('  本地游戏库 · 关联报告', 'h')
        line('=' * 68)
        line('根目录     : %s' % self.root_dir.get(), 'muted')
        line('游戏总数   : %d' % total, 'key')
        line('有金手指   : %d' % len(with_cheat), 'ok')
        line('缺金手指   : %d' % (total - len(with_cheat)), 'bad')
        line('命令合计   : %d' % n_cmd, 'ok')
        line('BIOS 文件  : %d' % len(self.bios), 'warn')
        line('孤立金手指 : %d (无对应游戏, 已保留在 chats/_orphans/)'
             % len(self.orphan_cheats), 'warn')
        rep = online_cheats.load_online_report(self.root_dir.get())
        if rep:
            line('联网补全   : %d 个 (可用「撤销联网适配」回退)' % len(rep), 'ok')
        line('')
        line('— 分平台 —', 'h')
        for plat in ('gba', 'nes', 'neogeo', 'cps1', 'cps2', 'arcade', ''):
            gs = [g for g in self.games if g['platform'] == plat]
            if not gs:
                continue
            wc = sum(1 for g in gs if g['cheats'])
            line('  %-8s 共 %3d    有金手指 %3d' %
                 (PLATFORM_LABEL.get(plat, plat), len(gs), wc),
                 'plat_' + (plat or 'none'))
        line('')
        missing = [g for g in self.games if not g['cheats']]
        line('— 无金手指的游戏 (%d) —' % len(missing), 'bad')
        for g in missing[:60]:
            line('  %-32s %s' % (g['stem'],
                                 PLATFORM_LABEL.get(g['platform'],
                                                    g['platform'])),
                 'plat_' + (g['platform'] or 'none'))
        if len(missing) > 60:
            line('  … 其余 %d 个已省略' % (len(missing) - 60), 'muted')
        line('')
        line('— 孤立金手指 (%d) —' % len(self.orphan_cheats), 'warn')
        for o in self.orphan_cheats[:60]:
            line('  %-52s %d 条' % (o['name'], len(o['cheats'])))
        if len(self.orphan_cheats) > 60:
            line('  … 其余 %d 个已省略' % (len(self.orphan_cheats) - 60),
                 'muted')
        t.configure(state='disabled')

    # ----------------------------------------------------------- 动作
    def clear_filters(self):
        self.query.set('')
        self.plat_filter.set('')
        self.cat_filter.set('')
        self.only_cheat.set(False)
        self.only_missing.set(False)
        self.refresh_table()

    def show_game_detail(self):
        tv = self.tv_games
        sel = tv.selection()
        if not sel:
            return
        g = next((x for x in self.games if x['path'] == sel[0]), None)
        if not g:
            return
        w = tk.Toplevel(self)
        w.title('游戏详情 — %s' % g['stem'])
        w.geometry('860x560')
        frm = ttk.Frame(w, padding=12)
        frm.pack(fill='both', expand=True)

        info = ttk.LabelFrame(frm, text=' 基本信息 ', padding=8)
        info.pack(fill='x')
        rows = [
            ('名称', g['stem']),
            ('中文名', g.get('name_cn') or '—'),
            ('文件', g['file']),
            ('平台', PLATFORM_LABEL.get(g['platform'], g['platform'])),
            ('分类', g['category']),
            ('大小', human_size(g['size'])),
            ('CRC32', g['crc'] or '(计算中)'),
            ('内部标题', g['internal'] or '—'),
            ('依赖 BIOS', ', '.join(PLATFORM_BIOS.get(g['platform'], [])) or '—'),
            ('路径', g['path']),
        ]
        for i, (k, v) in enumerate(rows):
            ttk.Label(info, text=k + ':', width=12,
                      anchor='e').grid(row=i, column=0, sticky='e', pady=2)
            ttk.Label(info, text=v, wraplength=560,
                      anchor='w').grid(row=i, column=1, sticky='w', pady=2)
        icon = g.get('icon') or ''
        if icon and os.path.isfile(icon):
            try:
                from PIL import Image, ImageTk
                im = Image.open(icon).convert('RGBA').resize((110, 110),
                                                            Image.LANCZOS)
                ph = ImageTk.PhotoImage(im)
                clbl = ttk.Label(info, image=ph)
                clbl.image = ph
                clbl.grid(row=0, column=2, rowspan=len(rows), sticky='ne',
                          padx=(10, 0))
            except Exception:
                pass

        cl = ttk.LabelFrame(frm, text=' 金手指 (%d 条) ' % len(g['cheats']),
                            padding=8)
        cl.pack(fill='both', expand=True, pady=(10, 0))
        tv2 = ttk.Treeview(cl, columns=('n', 'c'), show='headings')
        tv2.heading('n', text='名称')
        tv2.heading('c', text='命令 / 代码')
        tv2.column('n', width=300, anchor='w')
        tv2.column('c', width=480, anchor='w')
        sb = ttk.Scrollbar(cl, orient='vertical', command=tv2.yview)
        tv2.configure(yscrollcommand=sb.set)
        sb.pack(side='right', fill='y')
        tv2.pack(fill='both', expand=True)
        for c in g['cheats']:
            tv2.insert('', 'end', values=(c.get('name', ''),
                                          (c.get('code') or '').replace('\n', ' ')))

        btns = ttk.Frame(frm)
        btns.pack(fill='x', pady=(10, 0))
        ttk.Button(btns, text='打开所在文件夹',
                   command=lambda: self._open_folder(g['path'])).pack(side='left')
        ttk.Button(btns, text='关闭', command=w.destroy).pack(side='right')

    def _open_folder(self, path):
        folder = os.path.dirname(path)
        try:
            os.startfile(folder)  # noqa: S606 (Windows only, intentional)
        except Exception:
            try:
                subprocess.Popen(['explorer', folder])
            except Exception:
                pass

    def resync_cheats(self):
        script = os.path.abspath(os.path.join(_HERE, '..', 'chatsync',
                                              'sync_cheats.py'))
        if not os.path.isfile(script):
            messagebox.showerror('缺少脚本', '未找到 sync_cheats.py')
            return
        if not messagebox.askyesno('重新关联金手指',
                                   '将执行 sync_cheats.py 重建 chats/ 目录, '
                                   '会清空现有 chats 内容。继续?'):
            return
        self.status.set('正在重新关联金手指…')
        self.update_idletasks()
        try:
            r = subprocess.run([sys.executable, script],
                               capture_output=True, text=True,
                               encoding='utf-8', errors='replace')
            if r.returncode == 0:
                messagebox.showinfo('完成', '金手指已重新关联。')
            else:
                messagebox.showerror('失败', (r.stdout or '') + (r.stderr or ''))
        except Exception as ex:  # noqa: BLE001
            messagebox.showerror('失败', str(ex))
        self.scan(rescan=False)

    def export(self, kind: str):
        if not self.games:
            messagebox.showinfo('导出', '当前没有可导出的游戏。')
            return
        ext = '.csv' if kind == 'csv' else '.json'
        p = filedialog.asksaveasfilename(
            defaultextension=ext,
            filetypes=[('CSV', '*.csv')] if kind == 'csv'
            else [('JSON', '*.json')],
            initialfile='gamepouch_library' + ext)
        if not p:
            return
        try:
            if kind == 'csv':
                with open(p, 'w', newline='', encoding='utf-8-sig') as f:
                    w = csv.writer(f)
                    w.writerow(['名称', '平台', '分类', '大小(字节)', 'CRC32',
                                 '金手指数', '内部标题', '路径'])
                    for g in self.games:
                        w.writerow([g['stem'], g['platform'], g['category'],
                                    g['size'], g['crc'], len(g['cheats']),
                                    g['internal'], g['path']])
            else:
                data = [{
                    'name': g['stem'], 'platform': g['platform'],
                    'category': g['category'], 'size': g['size'],
                    'crc': g['crc'], 'internalTitle': g['internal'],
                    'path': g['path'],
                    'cheats': g['cheats'],
                } for g in self.games]
                with open(p, 'w', encoding='utf-8') as f:
                    json.dump({'version': 1, 'games': data}, f,
                              ensure_ascii=False, indent=2)
            messagebox.showinfo('导出完成', p)
        except Exception as ex:  # noqa: BLE001
            messagebox.showerror('导出失败', str(ex))

    def about(self):
        messagebox.showinfo(
            '关于',
            '趣玩匣 GamePouch · 本地游戏库管理\n\n'
            '统一管理本地 ROM / BIOS / 金手指:\n'
            '  · 游戏库 / 金手指 / BIOS / 关联报告 —— 分色展示\n'
            '  · 联网检索: 一键为缺失金手指的 ROM 上网补全\n'
            '  · 手机同步: USB(adb) 直推, 或局域网由手机主动拉取\n\n'
            '金手指与游戏按文件名主干一一对应, 并以 ROM 的 CRC32\n'
            '作为与手机端一致的关联键。除「联网检索」外全部离线运行。')

    # ----------------------------------------------------------- CRC 缓存
    def _cache_path(self):
        return os.path.join(_HERE, '.crc_cache.json')

    def _load_crc_cache(self):
        p = self._cache_path()
        if not os.path.isfile(p):
            return
        try:
            with open(p, 'r', encoding='utf-8') as f:
                raw = json.load(f)
            for k, v in raw.items():
                parts = k.rsplit('|', 2)
                if len(parts) == 3:
                    self.crc_cache[(parts[0], int(parts[1]), int(parts[2]))] = v
        except Exception:
            pass

    def _save_crc_cache(self):
        p = self._cache_path()
        try:
            data = {'%s|%d|%d' % k: v for k, v in self.crc_cache.items()}
            with open(p, 'w', encoding='utf-8') as f:
                json.dump(data, f)
        except Exception:
            pass


class CheatCmdDialog(tk.Toplevel):
    """单条金手指命令的编辑对话框(名称 / 代码 / 是否启用)。"""

    def __init__(self, parent, existing=None):
        super().__init__(parent)
        self.title('金手指命令' if existing is None else '编辑命令')
        self.result = None
        self.transient(parent)
        self.resizable(True, True)
        f = ttk.Frame(self, padding=12)
        f.pack(fill='both', expand=True)

        ttk.Label(f, text='名称').grid(row=0, column=0, sticky='w', pady=(0, 4))
        self.name = ttk.Entry(f, width=40)
        self.name.grid(row=0, column=1, sticky='ew', pady=(0, 4))

        ttk.Label(f, text='代码 / 命令').grid(row=1, column=0, sticky='nw',
                                              pady=(0, 4))
        self.code = tk.Text(f, width=40, height=4, wrap='word',
                            font=('Consolas', 10))
        self.code.grid(row=1, column=1, sticky='ew', pady=(0, 4))

        self.enabled = tk.BooleanVar(value=False)
        ttk.Checkbutton(f, text='默认启用(手机端可逐项开关)',
                        variable=self.enabled).grid(row=2, column=1,
                                                    sticky='w', pady=(0, 6))

        bb = ttk.Frame(f)
        bb.grid(row=3, column=0, columnspan=2, sticky='e')
        ttk.Button(bb, text='确定', style='Accent.TButton',
                   command=self._ok).pack(side='right')
        ttk.Button(bb, text='取消', command=self.destroy).pack(
            side='right', padx=(0, 6))

        f.columnconfigure(1, weight=1)
        if existing:
            self.name.insert(0, existing.get('name', ''))
            self.code.insert('1.0', existing.get('code', '') or '')
            self.enabled.set(bool(existing.get('enabled')))
        self.name.focus_set()

    def _ok(self):
        name = self.name.get().strip()
        code = self.code.get('1.0', 'end').strip()
        if not code:
            messagebox.showwarning('缺少代码', '金手指命令代码不能为空。',
                                   parent=self)
            return
        self.result = {
            'name': name or code.split('\n')[0][:24],
            'code': code, 'enabled': self.enabled.get(),
            'options': [], 'selected': -1,
        }
        self.destroy()


def main(argv=None):
    app = App()
    # --tab N: 启动后直接切到第 N 个页签(0 起), 方便脚本/截图定位
    argv = list(sys.argv[1:] if argv is None else argv)
    if '--tab' in argv:
        i = argv.index('--tab')
        try:
            n = int(argv[i + 1])
            app.after(200, lambda: app.nb.select(n))
        except (IndexError, ValueError):
            pass
    app.mainloop()


if __name__ == '__main__':
    main()
