"""游戏元数据查询器: 给 PC 游戏库补全中文名与图标(封面)。

数据源是一份游戏索引 JSON(约 1000 条), 每条含中文 ``title``、``crcFull``、
``platform``、``originalFile``, 以及可选的 ``cheats``(内联金手指) 与
``cover``(封面相对路径)。本模块按 **CRC32(精确)** 优先、**(平台, 英文名)**
次之 的方式把 PC 游戏库(gstest 等) 的游戏关联到索引, 补全:

* ``name_cn`` —— 中文名称;
* ``icon``    —— 封面图的绝对路径(供 PC 工具缩略图 + peer /api/peer/cover 下发)。

数据源定位顺序(第一个存在的胜出):

1. ``GAMEPOUCH_META_DIR`` 环境变量 —— 指向含索引 JSON 的目录(显式覆盖);
2. **仓库内置** ``tools/library/metadata`` —— 默认值, 随仓库分发, 不依赖任何
   外部项目(历史数据源自同级的 MyGameSim 项目, 该项目已移除, 索引已内联进来);
3. ``MYGAMESIM_DIR`` 环境变量 —— 遗留兼容, 读取旧的 ``library/index.json`` 布局。

> ⚠️ 模块**不再内置任何外部项目的绝对路径**。PC 工具必须自包含: 换一台机器
> clone 本仓库就能跑, 不需要旁边还躺着另一个项目。

索引缺的(多为 CPS/NeoGeo 不同 dump), 留空, 由"网络检索"另行补全
(见 skills.md)。封面图(covers/*.png)属第三方版权图片, **未随仓库分发**, 因此
``icon`` 在默认布局下通常为空; 如需封面可自行准备并通过 ``GAMEPOUCH_META_DIR``
指向含 ``covers/`` 的目录。
"""
import json
import os
import re

# ----------------------------------------------------------------- 探测根目录
#: 索引文件在数据源根下的相对位置(按顺序尝试)。仓库内置布局用 game_index.json,
#: 旧的 MyGameSim 布局用 library/index.json。
_INDEX_CANDIDATES = ('game_index.json', os.path.join('library', 'index.json'))

#: 仓库内置数据源目录(相对本文件)。默认且推荐的数据源。
_LOCAL_META_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'metadata')


def _find_index(root):
    """返回 root 下第一个存在的索引文件绝对路径, 没有则 None。"""
    if not root:
        return None
    for rel in _INDEX_CANDIDATES:
        p = os.path.join(root, rel)
        if os.path.isfile(p):
            return os.path.abspath(p)
    return None


def _detect_root():
    """定位游戏元数据索引, 返回其所在目录(不含索引文件名)。

    顺序: GAMEPOUCH_META_DIR(显式) -> 仓库内置 metadata -> MYGAMESIM_DIR(遗留)。
    **不探测任何兄弟项目路径** —— 本仓库的 PC 工具必须自包含。
    """
    for c in (os.environ.get('GAMEPOUCH_META_DIR'), _LOCAL_META_DIR,
              os.environ.get('MYGAMESIM_DIR')):
        if _find_index(c):
            return os.path.abspath(c)
    return None


def _norm(s: str) -> str:
    return re.sub(r'[^a-z0-9]', '', (s or '').lower())


class GameMeta:
    """游戏元数据的只读查询器(数据源见 :func:`_detect_root`)。"""

    def __init__(self, root: str | None = None):
        self.root = root or _detect_root()
        # 封面相对路径以索引所在目录为基准(旧布局是 <root>/library, 内置布局是
        # <root> 本身), 两者都由 index_path 的目录推导, 兼容两种布局。
        self.index_path = _find_index(self.root)
        self.lib = os.path.dirname(self.index_path) if self.index_path else None
        self.by_crc: dict[str, dict] = {}
        self.by_name: dict[tuple, dict] = {}
        self._load()

    # ----------------------------------------------------------- 加载
    def _load(self) -> None:
        if not self.index_path:
            return
        try:
            data = json.load(open(self.index_path, 'r', encoding='utf-8'))
        except Exception:
            return
        for e in data:
            if not isinstance(e, dict):
                continue
            c = e.get('crcFull')
            if c:
                self.by_crc.setdefault(str(c).upper(), e)
            of = e.get('originalFile') or ''
            stem = os.path.splitext(of)[0]
            if stem:
                self.by_name.setdefault((e.get('platform'), _norm(stem)), e)

    @property
    def available(self) -> bool:
        return bool(self.by_crc or self.by_name)

    # ----------------------------------------------------------- 查询
    def lookup(self, crc: str, platform: str, stem: str) -> dict | None:
        e = self.by_crc.get((crc or '').upper())
        if e:
            return e
        return self.by_name.get((platform, _norm(stem)))

    def name_cn(self, crc: str, platform: str, stem: str) -> str:
        e = self.lookup(crc, platform, stem)
        return (e.get('title') or '').strip() if e else ''

    def cover_path(self, crc: str, platform: str, stem: str) -> str | None:
        e = self.lookup(crc, platform, stem)
        if not e:
            return None
        cov = e.get('cover')
        if not cov:
            return None
        p = cov if os.path.isabs(cov) else os.path.join(self.lib, cov)
        return p if os.path.isfile(p) else None

    # ----------------------------------------------------------- 批量
    def enrich(self, games: list[dict]) -> None:
        """就地给 games 每条加上 ``name_cn`` 与 ``icon``。"""
        for g in games:
            crc = (g.get('crc') or '').upper()
            plat = g.get('platform') or ''
            stem = g.get('stem') or g.get('name') or ''
            g['name_cn'] = self.name_cn(crc, plat, stem)
            g['icon'] = self.cover_path(crc, plat, stem) or ''

    def covers_map(self, games: list[dict]) -> dict[str, str]:
        """返回 {CRC(大写): 封面绝对路径}, 供 peer 服务下发封面。"""
        out: dict[str, str] = {}
        for g in games:
            crc = (g.get('crc') or '').upper()
            p = self.cover_path(crc, g.get('platform') or '',
                                g.get('stem') or g.get('name') or '')
            if p:
                out[crc] = p
        return out


def load_meta() -> GameMeta:
    return GameMeta()
