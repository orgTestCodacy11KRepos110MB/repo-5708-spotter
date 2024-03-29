import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:observable/observable.dart';
import 'package:collection/collection.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:get_storage/get_storage.dart';
import 'package:process_run/shell.dart';

import 'api_service.dart';

typedef Action = bool Function(String query);
typedef OnNextOptions = void Function(List<Option> options);
typedef OnOptionQuery = List<Option> Function(String query);
typedef OptionAction = Future<bool> Function();

class Option {
  final String name;
  final String connectionId;
  final String? hint;
  final String? actionId;
  final String? onQueryId;
  final bool? important;
  final bool? isHovered;
  final int? priority;
  final String? icon;
  final OnOptionQuery? onQuery;
  final OptionAction? action;

  Option({
    required this.name,
    required this.connectionId,
    this.hint,
    this.actionId,
    this.onQueryId,
    this.important,
    this.isHovered,
    this.priority,
    this.icon,
    this.onQuery,
    this.action,
  });

  Option.fromJson(Map<String, dynamic> json)
      : name = json['name'],
        connectionId = json['connectionId'],
        hint = json['hint'],
        actionId = json['actionId'],
        onQueryId = json['onQueryId'],
        important = json['important'],
        isHovered = json['isHovered'],
        priority = json['priority'],
        icon = json['icon'],
        onQuery = null,
        action = null;

  Map<String, dynamic> toJson() => {
        'name': name,
        'connectionId': connectionId,
        'hint': hint,
        'actionId': actionId,
        'onQueryId': onQueryId,
        'important': important,
        'isHovered': isHovered,
        'priority': priority,
        'icon': icon,
        'onQuery': onQuery,
        'action': action,
      };
}

class ResponseWithOptionsFromPlugin {
  final String id;
  final String connectionId;
  final List<Option> options;
  final bool complete;

  ResponseWithOptionsFromPlugin({
    required this.id,
    required this.connectionId,
    required this.options,
    required this.complete,
  });

  ResponseWithOptionsFromPlugin.fromJson(Map<String, dynamic> json)
      : id = json['id'],
        connectionId = json['connectionId'],
        options = json['options'].map<Option>((o) {
          o['connectionId'] = json['connectionId'];
          return Option.fromJson(o);
        }).toList(),
        complete = json['complete'];

  Map<String, dynamic> toJson() => {
        'id': id,
        'connectionId': connectionId,
        'options': options,
        'complete': complete,
      };
}

class PluginToConnect {
  final String pluginName;
  final String id;

  PluginToConnect({
    required this.pluginName,
    required this.id,
  });
}

class PluginConnection {
  final String pluginName;
  final String id;
  final WebSocket socket;

  PluginConnection({
    required this.pluginName,
    required this.id,
    required this.socket,
  });
}

const port = 4040;

class PluginsServer {
  final storage = GetStorage('spotter');
  List<PluginToConnect> pluginsToConnect = [];
  ObservableList<PluginConnection> pluginConnections =
      ObservableList<PluginConnection>.from([]);
  final ApiService apiService = ApiService();
  final Shell shell = Shell();
  ObservableList<ResponseWithOptionsFromPlugin> responseWithOptionsRegistry =
      ObservableList<ResponseWithOptionsFromPlugin>.from([]);

  ObservableList<String> mlSuggestionsRegistry =
      ObservableList<String>.from([]);

  Future<bool> start() async {
    HttpServer server = await HttpServer.bind('0.0.0.0', port);
    server.transform(WebSocketTransformer()).listen(_handleConnection);

    storage.write('plugins_registry', []);
    // storage.writeIfNull('plugins_registry', []);
    List<String> pluginsRegistry = await getPluginsRegistry();

    for (var plugin in pluginsRegistry) {
      connectPlugin(plugin);
    }

    return true;
  }

  Future<bool> connectPlugin(String plugin) async {
    String connectionId = DateTime.now().millisecondsSinceEpoch.toString();
    pluginsToConnect.add(PluginToConnect(id: connectionId, pluginName: plugin));
    final pty = Pty.start('plugins/$plugin', arguments: [
      '--web-socket-port=$port',
      '--connection-id=$connectionId'
    ]);

    pty.output.cast<List<int>>().transform(const Utf8Decoder()).listen((text) {
      print(text);
    });

    try {
      await findConnectedPlugin(connectionId)
          .timeout(const Duration(minutes: 5));

      return true;
    } catch (err) {
      return false;
    }
  }

  Future<PluginConnection> findConnectedPlugin(String connectionId) async {
    Completer<PluginConnection> completer = Completer();
    pluginConnections.changes.listen((_) {
      final response = pluginConnections.toList().firstWhereOrNull(
            (c) => c.id == connectionId,
          );

      if (response != null) {
        completer.complete(response);
      }
    });

    return completer.future;
  }

  Future<List<String>> getPluginsRegistry() async {
    final storagePluginsRegistry = storage.read('plugins_registry') ?? [];
    final existingPlugins = <String>[];
    await Future.forEach(storagePluginsRegistry, (plugin) async {
      final pluginExists = await File('./plugins/$plugin').exists();
      if (pluginExists) {
        existingPlugins.add(plugin as String);
      }
    });
    return existingPlugins;
  }

  Future<bool> installPlugin(String plugin) async {
    List<String> pluginsRegistry = await getPluginsRegistry();

    bool alreadyRegistered = pluginsRegistry.firstWhereOrNull(
            (registeredPlugin) => registeredPlugin.contains(plugin)) !=
        null;

    // TODO: check
    if (alreadyRegistered) {
      await removePlugin(plugin);
    }

    // TODO: return single item
    List<ReleaseAsset>? assets =
        await apiService.getLatestReleaseAssets(plugin);

    if (assets == null) {
      return false;
    }

    await shell.run('mkdir -p plugins/$plugin');
    await Future.wait(assets.map((asset) async {
      String name = asset.name;
      String url = asset.url;
      await shell.run('curl -o plugins/$plugin/$name -LO "$url"');
      await shell.run('chmod 777 plugins/$plugin/$name');
      await shell.run('ls plugins/$plugin');
      await connectPlugin('$plugin/$name');
      storage.write('plugins_registry', [...pluginsRegistry, '$plugin/$name']);
    }));

    return true;
  }

  removePlugin(String plugin) async {
    // TODO: remove from connections
    await shell.run('rm -rf plugins/$plugin');
    List<String> pluginPath = plugin.split('/');
    String pluginName = pluginPath[1];
    String platform = Platform.isLinux ? 'linux' : 'macos';
    String pluginFullName = '$pluginName-$platform';
    List<String> pluginsRegistry = await getPluginsRegistry();
    storage.write(
        'plugins_registry', pluginsRegistry.where((p) => p != plugin));

    try {
      await shell.run('killall $pluginFullName');
    } catch (err) {
      return;
    }
  }

  Future<ResponseWithOptionsFromPlugin> findResponseWithOptionsFromPlugin(
      String requestId) async {
    Completer<ResponseWithOptionsFromPlugin> completer = Completer();
    responseWithOptionsRegistry.changes.listen((_) {
      final response = responseWithOptionsRegistry.toList().firstWhereOrNull(
            (r) => r.id == requestId,
          );

      if (response != null) {
        responseWithOptionsRegistry.remove(response);
        completer.complete(response);
      }
    });

    return completer.future;
  }

  Future<List<Option>> onQuery(String query) async {
    if (pluginConnections.isEmpty) {
      return [];
    }

    final options = <Option>[];
    await Future.forEach(pluginConnections, (connection) async {
      String requestId = DateTime.now().millisecondsSinceEpoch.toString();
      connection.socket.add(
          '{"id": "$requestId", "type": "onQueryRequest", "query": "$query"}');
      ResponseWithOptionsFromPlugin response =
          await findResponseWithOptionsFromPlugin(requestId);
      options.addAll(response.options);
    });
    return options;
  }

  Future<List<Option>?> onOptionQuery(
      String onQueryId, String query, String connectionId) async {
    PluginConnection? connection = pluginConnections.firstWhereOrNull(
      (connection) => connection.id == connectionId,
    );

    if (connection == null) {
      return null;
    }

    String requestId = DateTime.now().millisecondsSinceEpoch.toString();
    connection.socket!.add(
        '{"id": "$requestId", "type": "onOptionQueryRequest", "onQueryId": "$onQueryId", "query": "$query"}');
    ResponseWithOptionsFromPlugin response =
        await findResponseWithOptionsFromPlugin(requestId);
    return response.options;
  }

  Future<ResponseWithOptionsFromPlugin?> execAction(
      String actionId, String connectionId) async {
    PluginConnection? connection = pluginConnections.firstWhereOrNull(
      (connection) => connection.id == connectionId,
    );

    if (connection == null) {
      return null;
    }

    String requestId = DateTime.now().millisecondsSinceEpoch.toString();
    connection.socket.add(
        '{"id": "$requestId", "type": "execActionRequest", "actionId": "$actionId"}');
    ResponseWithOptionsFromPlugin response =
        await findResponseWithOptionsFromPlugin(requestId);
    return response;
  }

  mlAddSuggestionToList(String globalActionPath) {
    mlSuggestionsRegistry.add(globalActionPath);
    Iterable<String> nextMlSuggestionsRegistry = [
      ...mlSuggestionsRegistry.take(2),
      globalActionPath
    ];
    mlSuggestionsRegistry.clear();
    mlSuggestionsRegistry.addAll(nextMlSuggestionsRegistry);
  }

  mlSendGlobalActionPath(String globalActionPath) async {
    for (var connection in pluginConnections) {
      connection.socket.add(
          '{"type": "mlSaveSuggestion", "mlGlobalActionPath": "$globalActionPath"}');
    }
  }

  onOpenSpotter() async {
    for (var connection in pluginConnections) {
      if (connection.socket == null) {
        return;
      }
      connection.socket.add('{"type": "onOpenSpotter"}');
    }
  }

  _handleConnection(WebSocket socket) {
    socket.listen((event) {
      String? connectionId;
      final json = jsonDecode(event);
      final messageType = json['type'];

      if (messageType == 'pluginReady') {
        connectionId = json['connectionId'];

        PluginToConnect? pluginToConnect = pluginsToConnect
            .toList()
            .firstWhereOrNull((c) => c.id == connectionId);

        if (pluginToConnect == null) {
          pluginConnections.add(
              PluginConnection(pluginName: 'dev', id: 'dev', socket: socket));
        } else {
          pluginConnections.add(PluginConnection(
              pluginName: pluginToConnect.pluginName,
              id: pluginToConnect.id,
              socket: socket));
          pluginsToConnect.remove(pluginToConnect);
        }
        return;
      }

      if (messageType == 'mlSuggestions') {
        mlAddSuggestionToList(json['mlGlobalActionPath']);
        return;
      }

      if (messageType == 'onQueryResponse' ||
          messageType == 'onOptionQueryResponse' ||
          messageType == 'execActionResponse') {
        if (json['connectionId'] == null) {
          json['connectionId'] = 'dev';
        }
        ResponseWithOptionsFromPlugin response =
            ResponseWithOptionsFromPlugin.fromJson(json);
        responseWithOptionsRegistry.add(response);
        return;
      }
    }, onDone: () {
      // TODO:
      // responseWithOptionsRegistry
      //     .removeWhere((response) => response.connectionId == connectionId);
      // pluginConnections
      //     .removeWhere((connection) => connection.id == connectionId);
    }, onError: (error) {
      // responseWithOptionsRegistry
      //     .removeWhere((response) => response.connectionId == connectionId);
      // pluginConnections
      //     .removeWhere((connection) => connection.id == connectionId);
    });
  }
}
