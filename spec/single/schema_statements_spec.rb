# frozen_string_literal: true

RSpec.describe 'ActiveRecord::ConnectionAdapters::Clickhouse::SchemaStatements' do
  let(:connection) { ActiveRecord::Base.connection }

  describe '#add_index_options' do
    it 'generates the index name' do
      index = connection.add_index_options('profiles', 'tupleElement(full_name_state, 2)', type: 'bloom_filter')

      expect(index.name).to eq('index_profiles_on_tupleElement_full_name_state_2')
    end
  end

  describe '#projections' do
    before do
      connection.execute('CREATE TABLE projection_test (id UInt64, value Float64, happened_on Date32, happened_at DateTime64(6, \'UTC\'), PROJECTION by_id (SELECT * ORDER BY id)) ENGINE = MergeTree ORDER BY id')
    end

    after { connection.execute('DROP TABLE IF EXISTS projection_test') }

    it 'returns the projection definitions' do
      expect(connection.projections('projection_test')).to eq([{ 'name' => 'by_id', 'query' => 'SELECT * ORDER BY id' }])
    end

    it 'dumps exact types and projections' do
      require 'clickhouse-activerecord/schema_dumper'

      schema = StringIO.new
      ClickhouseActiverecord::SchemaDumper.dump(connection, schema)

      expect(schema.string).to include('t.column "value", "Float64"')
      expect(schema.string).to include('t.column "happened_on", "Date32"')
      expect(schema.string).to include('t.column "happened_at", "DateTime64(6, \'UTC\')"')
      expect(schema.string).to include('execute "ALTER TABLE projection_test ADD PROJECTION by_id (SELECT * ORDER BY id)"')
    end
  end

  describe '#truncate_tables' do
    before do
      connection.execute('CREATE TABLE truncate_test (id UInt64, name String) ENGINE = MergeTree ORDER BY id')
    end

    after do
      connection.execute('DROP DICTIONARY IF EXISTS truncate_test_dict')
      connection.execute('DROP TABLE IF EXISTS truncate_test')
      connection.execute('DROP TABLE IF EXISTS truncate_test2')
      connection.execute('DROP VIEW IF EXISTS truncate_test_view')
    end

    it 'truncates multiple tables' do
      connection.execute('CREATE TABLE truncate_test2 (id UInt64, value Int32) ENGINE = MergeTree ORDER BY id')
      connection.exec_insert("INSERT INTO truncate_test (id, name) VALUES (1, 'Alice'), (2, 'Bob')")
      connection.exec_insert("INSERT INTO truncate_test2 (id, value) VALUES (1, 100), (2, 200)")

      expect(connection.select_value('SELECT count() FROM truncate_test').to_i).to eq(2)
      expect(connection.select_value('SELECT count() FROM truncate_test2').to_i).to eq(2)

      connection.truncate_tables('truncate_test', 'truncate_test2')

      expect(connection.select_value('SELECT count() FROM truncate_test').to_i).to eq(0)
      expect(connection.select_value('SELECT count() FROM truncate_test2').to_i).to eq(0)
    end

    it 'skips tables with unsupported engines' do
      connection.execute('CREATE VIEW truncate_test_view AS SELECT * FROM truncate_test')
      connection.execute(<<~SQL)
        CREATE DICTIONARY truncate_test_dict (
          id UInt64,
          name String
        )
        PRIMARY KEY id
        SOURCE(CLICKHOUSE(TABLE 'truncate_test'))
        LIFETIME(MIN 0 MAX 0)
        LAYOUT(FLAT())
      SQL
      connection.exec_insert("INSERT INTO truncate_test (id, name) VALUES (1, 'Alice')")

      expect { connection.truncate_tables(*connection.tables) }.not_to raise_error

      expect(connection.select_value('SELECT count() FROM truncate_test').to_i).to eq(0)
    end
  end
end
