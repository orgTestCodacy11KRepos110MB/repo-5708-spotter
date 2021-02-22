import {
  SpotterOption,
  SpotterPlugin,
  SpotterPluginLifecycle,
  spotterSearch,
} from '../../core';

export class FinderPlugin extends SpotterPlugin implements SpotterPluginLifecycle {

  identifier = 'Finder';

  onQuery(query: string): SpotterOption[] {
    return [];
    // return spotterSearch(query, [{
    //   title: 'Finder',
    //   subtitle: '/System/Library/CoreServices/Finder.app',
    //   icon: '/System/Library/CoreServices/Finder.app',
    //   action: () => this.nativeModules.shell.execute('open ~'),
    // }]);
  }

}

