
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { GamePouchPlugin } from '../plugins/GamePouchPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    // P3: register the in-app native handler plugin for OhosPal's channels.
    // Also stash the UIAbilityContext (needed by @ohos.file.picker for
    // import/export) because onAttachedToEngine only exposes an
    // ApplicationContext.
    GamePouchPlugin.setAbilityContext(this.context)
    flutterEngine.getPlugins()?.add(new GamePouchPlugin(this.context))
  }
}
