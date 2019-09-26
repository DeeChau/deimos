# frozen_string_literal: true

require 'deimos/schema_model_converter'

describe Deimos::SchemaModelConverter do
  # Create ActiveRecord table and model
  before(:all) do
    ActiveRecord::Base.connection.create_table(:wibbles, force: true) do |t|
      t.integer(:wibble_id)
      t.string(:name)
      t.integer(:bar)
      t.datetime(:birthday_int)
      t.datetime(:birthday_long)
      t.datetime(:birthday_optional)
      t.timestamps
    end

    # :nodoc:
    class Wibble < ActiveRecord::Base
    end
    Wibble.reset_column_information
  end

  after(:all) do
    ActiveRecord::Base.connection.drop_table(:wibbles)
  end

  let(:schema_store) { AvroTurf::SchemaStore.new(path: Deimos.config.schema_path) }
  let(:schema) { schema_store.find('Wibble', 'com.my-namespace') }
  let(:inst) { described_class.new(schema, Wibble) }

  describe '#convert' do
    it 'should extract attributes from the payload' do
      payload = { 'id' => 123, 'wibble_id' => 456, 'name' => 'wibble' }

      expect(inst.convert(payload)).to include('id' => 123, 'wibble_id' => 456, 'name' => 'wibble')
    end

    it 'should ignore payload fields that don\'t exist' do
      payload = { 'foo' => 'abc' }

      expect(inst.convert(payload)).not_to include('foo')
    end

    it 'should ignore schema fields not in the model' do
      payload = { 'floop' => 'def' }

      expect(inst.convert(payload)).not_to include('floop')
    end

    it 'should ignore model fields not in the schema' do
      payload = { 'bar' => 'xyz' }

      expect(inst.convert(payload)).not_to include('bar')
    end

    it 'should ignore AR timestamp fields' do
      payload = { 'updated_at' => '1234567890', 'created_at' => '2345678901' }

      expect(inst.convert(payload)).not_to include('updated_at', 'created_at')
    end

    it 'should handle nils' do
      payload = { 'name' => nil }

      expect(inst.convert(payload)['name']).to be_nil
    end

    it 'should parse timestamps' do
      first = Time.zone.local(2019, 1, 1, 11, 12, 13)
      second = Time.zone.local(2019, 2, 2, 12, 13, 14)

      payload = { 'birthday_int' => first.to_i, 'birthday_long' => second.to_i }

      expect(inst.convert(payload)).to include('birthday_int' => first, 'birthday_long' => second)
    end

    it 'should coerce nullable unions' do
      date = Time.zone.local(2019, 1, 1, 11, 12, 13)

      payload = { 'birthday_optional' => date.to_i }

      expect(inst.convert(payload)).to include('birthday_optional' => date)
    end
  end
end
