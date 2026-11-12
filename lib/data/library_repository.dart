import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'library_models.dart';

/// Only managed originals and completed, verified playback copies are indexed.
class LibraryRepository {
  LibraryRepository._(this.root, this._database);
  final Directory root;
  final Database _database;
  Directory get originals =>
      Directory(p.join(root.path, 'library', 'originals'));
  Directory get playable => Directory(p.join(root.path, 'library', 'playable'));
  Directory get temporary => Directory(p.join(root.path, 'temp'));

  static Future<LibraryRepository> open(Directory root) async {
    await Directory(p.join(root.path, 'database')).create(recursive: true);
    final database = sqlite3.open(
      p.join(root.path, 'database', 'heming.sqlite'),
    );
    database.execute('PRAGMA journal_mode = WAL');
    database.execute(
      'CREATE TABLE IF NOT EXISTS library (id TEXT PRIMARY KEY, imported_at TEXT NOT NULL, data TEXT NOT NULL)',
    );
    database.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    // Existing library JSON remains valid: absent group fields mean ungrouped.
    database.execute(
      'CREATE TABLE IF NOT EXISTS library_groups (id TEXT PRIMARY KEY, name TEXT NOT NULL, sort_order INTEGER NOT NULL)',
    );
    final repository = LibraryRepository._(root, database);
    for (final directory in [
      repository.originals,
      repository.playable,
      repository.temporary,
    ]) {
      await directory.create(recursive: true);
    }
    return repository;
  }

  List<LibraryItem> loadItems() => _database
      .select('SELECT data FROM library ORDER BY imported_at DESC, id')
      .map(
        (row) => LibraryItem.fromJson(
          jsonDecode(row['data'] as String) as Map<String, dynamic>,
        ),
      )
      .toList();
  void save(LibraryItem item) => _database.execute(
    'INSERT INTO library(id, imported_at, data) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data',
    [item.id, item.importedAt.toIso8601String(), jsonEncode(item.toJson())],
  );
  void remove(String id) =>
      _database.execute('DELETE FROM library WHERE id = ?', [id]);

  List<LibraryGroup> loadGroups() => _database
      .select(
        'SELECT id, name, sort_order FROM library_groups ORDER BY sort_order, id',
      )
      .map(
        (row) => LibraryGroup(
          id: row['id'] as String,
          name: row['name'] as String,
          sortOrder: row['sort_order'] as int,
        ),
      )
      .toList();

  void saveGroup(LibraryGroup group) => _database.execute(
    'INSERT INTO library_groups(id, name, sort_order) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, sort_order = excluded.sort_order',
    [group.id, group.name, group.sortOrder],
  );

  /// Group changes commit together, without touching any media files.
  void saveGroupAssignments(List<LibraryItem> items, {String? deleteGroupId}) {
    _database.execute('BEGIN TRANSACTION');
    try {
      for (final item in items) {
        save(item);
      }
      if (deleteGroupId != null) {
        _database.execute('DELETE FROM library_groups WHERE id = ?', [
          deleteGroupId,
        ]);
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  String? setting(String key) {
    final rows = _database.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) => _database.execute(
    'INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [key, value],
  );
  void close() => _database.close();
}
