import 'dart:io';
import 'package:aqueduct/aqueduct.dart';
import 'package:test/test.dart';
import 'generate_helpers.dart';
import 'package:postgres/postgres.dart';

void main() {
  group("Schema diffs", () {
    var migrationDirectory = new Directory("tmp_migrations/migrations");
    PostgreSQLConnection connection;

    setUp(() async {
      connection = new PostgreSQLConnection("localhost", 5432, "dart_test",
          username: "dart", password: "dart");
      await connection.open();
      migrationDirectory.createSync(recursive: true);
    });

    tearDown(() async {
      migrationDirectory.parent.deleteSync(recursive: true);

      for (var tableName in ["v", "u", "t"]) {
        await connection.execute("DROP TABLE IF EXISTS $tableName");
      }

      await connection.execute("DROP TABLE IF EXISTS _aqueduct_version_pgsql");
      await connection.close();
    });

    /*
    Tables
     */

    test("Table that is new to destination schema emits createTable", () async {
      await writeMigrations(migrationDirectory, [
        new Schema.empty(),
        new Schema([
          new SchemaTable("t", [
            new SchemaColumn("id", ManagedPropertyType.integer,
                isPrimaryKey: true)
          ])
        ])
      ]);

      await executeMigrations(migrationDirectory.parent);

      var results =
      await connection.query("INSERT INTO t (id) VALUES (1) RETURNING id");
      expect(results, [
        [1]
      ]);
    });

    test("Table that is no longer in destination schema emits deleteTable",
            () async {
          var schemas = [
            new Schema.empty(),
            new Schema([
              new SchemaTable("u", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true)
              ]),
              new SchemaTable("t", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true)
              ])
            ]),
            new Schema([
              new SchemaTable("u", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true)
              ]),
            ]),
          ];

          await writeMigrations(migrationDirectory, schemas.sublist(0, 2));
          await executeMigrations(migrationDirectory.parent);

          var results =
          await connection.query("INSERT INTO t (id) VALUES (1) RETURNING id");
          expect(results, [
            [1]
          ]);
          results =
          await connection.query("INSERT INTO u (id) VALUES (1) RETURNING id");
          expect(results, [
            [1]
          ]);

          await writeMigrations(migrationDirectory, schemas.sublist(1));
          await executeMigrations(migrationDirectory.parent);

          results =
          await connection.query("INSERT INTO u (id) VALUES (2) RETURNING id");
          expect(results, [
            [2]
          ]);
          try {
            await connection.query("INSERT INTO t (id) VALUES (1) RETURNING id");
            expect(true, false);
          } on PostgreSQLException catch (e) {
            expect(e.message, contains("relation \"t\" does not exist"));
          }
        });

    test(
        "Two tables to be deleted that are order-dependent because of constraints are added/deleted in the right order",
            () async {
          var schemas = [
            new Schema.empty(),
            new Schema([
              new SchemaTable("t", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true)
              ]),
              new SchemaTable("u", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true),
                new SchemaColumn.relationship("ref", ManagedPropertyType.integer,
                    relatedTableName: "t", relatedColumnName: "id")
              ]),
            ]),
            new Schema.empty()
          ];
          await writeMigrations(migrationDirectory, schemas.sublist(0, 2));
          await executeMigrations(migrationDirectory.parent);

          // We try and delete this in the wrong order to ensure that when we do delete it,
          // we're actually solving a problem.
          try {
            await connection.execute("DROP TABLE t");
            expect(true, false);
          } on PostgreSQLException catch (e) {
            expect(e.message, contains("cannot drop table t"));
          }

          await writeMigrations(migrationDirectory, schemas.sublist(1));
          await executeMigrations(migrationDirectory.parent);

          try {
            await connection.query("INSERT INTO t (id) VALUES (1) RETURNING id");
            expect(true, false);
          } on PostgreSQLException catch (e) {
            expect(e.message, contains("relation \"t\" does not exist"));
          }

          try {
            await connection.query("INSERT INTO u (id) VALUES (1) RETURNING id");
            expect(true, false);
          } on PostgreSQLException catch (e) {
            expect(e.message, contains("relation \"u\" does not exist"));
          }
        });

    test(
        "Repeat of above, reverse order: Two tables to be added/deleted that are order-dependent because of constraints are deleted in the right order",
            () async {
          var schemas = [
            new Schema.empty(),
            new Schema([
              new SchemaTable("u", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true),
                new SchemaColumn.relationship("ref", ManagedPropertyType.integer,
                    relatedTableName: "t", relatedColumnName: "id")
              ]),
              new SchemaTable("t", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true)
              ]),
            ]),
            new Schema.empty()
          ];

          await writeMigrations(migrationDirectory, schemas);
          await executeMigrations(migrationDirectory.parent);

          try {
            await connection.query("INSERT INTO t (id) VALUES (1) RETURNING id");
            expect(true, false);
          } on PostgreSQLException catch (e) {
            expect(e.message, contains("relation \"t\" does not exist"));
          }

          try {
            await connection.query("INSERT INTO u (id) VALUES (1) RETURNING id");
            expect(true, false);
          } on PostgreSQLException catch (e) {
            expect(e.message, contains("relation \"u\" does not exist"));
          }
        });

    test("Add new table with fkey ref to previous table", () async {
      var schemas = [
        new Schema.empty(),
        new Schema([
          new SchemaTable("t", [
            new SchemaColumn("id", ManagedPropertyType.integer,
                isPrimaryKey: true)
          ]),
        ]),
        new Schema([
          new SchemaTable("t", [
            new SchemaColumn("id", ManagedPropertyType.integer,
                isPrimaryKey: true)
          ]),
          new SchemaTable("u", [
            new SchemaColumn("id", ManagedPropertyType.integer,
                isPrimaryKey: true),
            new SchemaColumn.relationship("ref", ManagedPropertyType.integer,
                relatedTableName: "t", relatedColumnName: "id")
          ]),
        ])
      ];

      await writeMigrations(migrationDirectory, schemas);
      await executeMigrations(migrationDirectory.parent);

      await connection.query("INSERT INTO t (id) VALUES (1)");
      var results = await connection.query(
          "INSERT INTO u (id, ref_id) VALUES (1, 1) RETURNING id, ref_id");
      expect(results, [
        [1, 1]
      ]);
    });

    test("Add new table, and add foreign key to that table from existing table",
            () async {
          var schemas = [
            new Schema.empty(),
            new Schema([
              new SchemaTable("u", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true)
              ]),
            ]),
            new Schema([
              new SchemaTable("u", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true),
                new SchemaColumn.relationship("ref", ManagedPropertyType.integer,
                    relatedTableName: "t", relatedColumnName: "id")
              ]),
              new SchemaTable("t", [
                new SchemaColumn("id", ManagedPropertyType.integer,
                    isPrimaryKey: true),
              ]),
            ])
          ];

          await writeMigrations(migrationDirectory, schemas);
          await executeMigrations(migrationDirectory.parent);

          await connection.query("INSERT INTO t (id) VALUES (1)");
          var results = await connection.query(
              "INSERT INTO u (id, ref_id) VALUES (1, 1) RETURNING id, ref_id");
          expect(results, [
            [1, 1]
          ]);
        });
  });
}