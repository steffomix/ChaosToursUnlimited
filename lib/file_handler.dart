import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart' as pp;
import 'package:external_path/external_path.dart';

///
import 'package:chaostours/logger.dart';
import 'package:chaostours/shared.dart';
import 'package:chaostours/globals.dart';

////

var decode = Uri.decodeFull; // util.base64Codec().decode;
var encode = Uri.encodeFull; //util.base64Codec().encode;

enum Storages {
  /// app installation directory
  /// unreachable
  appInternal,

  /// app data directory of internal storage
  /// .android/data/com.stefanbrinkmann.chaostours/files/chaostours/1.0
  /// on new devices only reachable with Computer and Datacable
  appLocalStorageData,

  /// app data directory of internal storage
  /// localStorage/Documents
  /// on new devices only reachable with Computer and Datacable
  appLocalStorageDocuments,

  /// Documents on sdCard
  /// <sdCard>/Documents/chaostours/1.0
  appSdCardDocuments;
}

enum FileHandlerStatus {
  /// nothing tried/loaded yet
  unknown,

  /// damaged Shared key
  sharedKeyInvalid,

  /// storage no longer writeable / removed
  storageDestroyed,

  /// no storage found whatsoever
  noStorageAvailable,

  /// storage found
  storageOk
}

class FileHandler {
  static List<FileHandlerStatus> _status = [FileHandlerStatus.unknown];
  static FileHandlerStatus get status => _status.last;
  static List<FileHandlerStatus> get statusHistory => [..._status];

  /// storage
  static Storages storageKey = Storages.appInternal;
  static String? storagePath;

  static Logger logger = Logger.logger<FileHandler>();
  static const lineSep = '\n';
  static Future<Directory> get appDir async {
    Directory dir = Directory(
        storagePath ?? (await pp.getApplicationDocumentsDirectory()).path);
    if (dir.path != storagePath) {
      await logger.warn(
          '#\nStorage path missmatch, Should be "${storagePath}", but fallback to ${dir.path}\n#');
    }
    return dir;
  }

  static Future<File> getFile(String filename) async {
    String f = '${filename.toLowerCase()}.txt';
    f = join((await appDir).path, f);
    await logger.log('request access to File $f');
    File file = File(f);
    bool exists = await file.exists();
    if (!exists) {
      try {
        await logger.important('file does not exist, create file $f');
        file = await file.create(recursive: true);
      } catch (e, stk) {
        print('${e.toString()}\n $stk');
        rethrow;
      }
    }
    return file;
  }

  static Future<int> write(String filename, String content) async {
    File file = await getFile(filename);
    await file.writeAsString(content);
    await logger.log('write ${content.length} bytes to $filename');
    return file.lengthSync();
  }

  static Future<String> read(String filename) async {
    String content = await (await getFile(filename)).readAsString();
    await logger.log('read ${content.length} bytes from $filename');
    return content;
  }

  static Future<int> writeTable<T>(List<String> table) async {
    File file = await getFile(T.toString());
    await file.writeAsString(table.join(lineSep));
    await logger.log('write ${table.length} rows to $file');
    return file.lengthSync();
  }

  static Future<List<String>> readTable<T>() async {
    File file = await getFile(T.toString());
    String data = await file.readAsString();
    if (data.trim().isEmpty) {
      return <String>[];
    }
    List<String> lines = data.split(lineSep);
    await logger.log('read ${lines.length} rows from $file');
    return lines;
  }

  ///
  ///
  ///
  /// ################# Instance #############
  ///
  ///   Detect and set storage to Shared data and Globals
  ///
  ///
  ///

  ///
  Future<String?> getStorage() async {
    Map<Storages, String?> storages = await _getAllStorages();
    String? key = await Shared(SharedKeys.storageKey).loadString();
    await logger.important('found storage key: $key');
    if (key == null) {
      /// nothing saved by user yet, find one
      String? sto = await _getAutoPath();
      if (sto == null) {
        _status.add(FileHandlerStatus.noStorageAvailable);
      } else {
        _status.add(FileHandlerStatus.storageOk);
        return sto;
      }
    } else {
      try {
        /// key must be valid
        Storages storage = Storages.values.byName(key);
        if (await lookupStorage(storage)) {
          _status.add(FileHandlerStatus.storageOk);

          /// found a valid storage
          return storages[storage];
        } else {
          _status.add(FileHandlerStatus.storageDestroyed);

          /// try to find a storage
          String? sto = await _getAutoPath();
          if (sto == null) {
            /// nothing found
            _status.add(FileHandlerStatus.noStorageAvailable);
            return null;
          } else {
            /// found storage
            _status.add(FileHandlerStatus.storageOk);
            return sto;
          }
        }
      } catch (e) {
        _status.add(FileHandlerStatus.sharedKeyInvalid);
        logger
            .warn('shared storage key does not exist, try to find a fallback');

        /// nothing saved by user yet, find one
        String? sto = await _getAutoPath();
        if (sto == null) {
          _status.add(FileHandlerStatus.noStorageAvailable);
        } else {
          _status.add(FileHandlerStatus.storageOk);
          return sto;
        }
      }
    }
  }

  /// Maps enum Storage: Directory.path
  static final Map<Storages, String?> storages = {
    Storages.appInternal: null,
    Storages.appLocalStorageData: null,
    Storages.appLocalStorageDocuments: null,
    Storages.appSdCardDocuments: null
  };

  Future<Map<Storages, String?>> _getAllStorages() async {
    for (Storages key in storages.keys) {
      await lookupStorage(key);
    }
    return storages;
  }

  Future<String?> _getAutoPath() async {
    List<Storages> storageLookupOrder = [
      Storages.appSdCardDocuments,
      Storages.appLocalStorageDocuments,
      Storages.appLocalStorageData,
      Storages.appInternal,
    ];
    await _getAllStorages();
    for (var key in storageLookupOrder) {
      if (storages[key] != null) {
        await _setStorage(key, storages[key]!);
        return storages[key]!;
      }
    }
    return null;
  }

  Future<void> _setStorage(Storages key, String path) async {
    storageKey = key;
    storagePath = path;
    await Shared(SharedKeys.storageKey).saveString(key.name);
    await Shared(SharedKeys.storagePath).saveString(path);
    await logger.important('set storage path ${key.name}::$path');
  }

  /// try to create a file
  /// if the file already exists, we assume that this dir is writable.
  /// if create file fails, we can`t use it
  Future<void> _createBaseDir(String path, Storages target) async {
    Directory dir = Directory(path);
    //! thows exception
    File file = File(join(path, 'readme2.txt'));
    bool fileExists = await file.exists();
    if (!fileExists) {
      logger.important('try to create base dir / file : ${file.absolute}');
      await dir.create(recursive: true);
      await file.create(recursive: true);
      //
    }

    storages[target] = dir.path;
    await logger.log('${target.name}::${dir.path}');
  }

  /// looks whether a file can be created and set the path
  /// to the FileManager.storages Map
  Future<bool> lookupStorage(Storages storage) async {
    await logger.log('lookup Storage ${storage.name}');

    switch (storage) {
      case Storages.appInternal:

        /// internal storages
        try {
          Directory appDir = await pp.getApplicationDocumentsDirectory();
          String path = join(appDir.path, 'version_${Globals.version}');
          await _createBaseDir(path, Storages.appInternal);
          return true;
        } catch (e, stk) {
          await logger.error(e.toString(), stk);
        }
        return false;
      case Storages.appLocalStorageData:

        /// external storage
        try {
          var appDir = await pp.getExternalStorageDirectory();
          if (appDir?.path != null) {
            String path = join(appDir!.path, 'version_${Globals.version}');
            await _createBaseDir(path, Storages.appLocalStorageData);
            return true;
          }
        } catch (e, stk) {
          logger.error(e.toString(), stk);
        }
        return false;
      case Storages.appLocalStorageDocuments:

        /// Phone Documents
        try {
          List<String> pathes =
              await ExternalPath.getExternalStorageDirectories();
          String path = join(pathes[0], ExternalPath.DIRECTORY_DOCUMENTS,
              'ChaosTours', 'version_${Globals.version}');
          await _createBaseDir(path, Storages.appLocalStorageDocuments);
          return true;
        } catch (e, stk) {
          await logger.error(e.toString(), stk);
        }

        return false;
      case Storages.appSdCardDocuments:

        /// sdCard documents
        try {
          List<String> pathes =
              await ExternalPath.getExternalStorageDirectories();
          String path = join(pathes[1], ExternalPath.DIRECTORY_DOCUMENTS,
              'ChaosTours', 'version_${Globals.version}');
          await _createBaseDir(path, Storages.appSdCardDocuments);
          return true;
        } catch (e, stk) {
          await logger.error(e.toString(), stk);
        }
        return false;

      default:
        throw 'Storage $storage has no lookup method';
    }
  }
}
