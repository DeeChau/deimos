# frozen_string_literal: true

require 'generators/deimos/active_record_generator'

RSpec.describe Deimos::Generators::ActiveRecordGenerator do

  after(:each) do
    FileUtils.rm_rf('db') if File.exist?('db')
    FileUtils.rm_rf('app') if File.exist?('app')
  end

  it 'should generate a migration' do
    expect(Dir['db/migrate/*.rb']).to be_empty
    expect(Dir['app/models/*.rb']).to be_empty
    described_class.start(['generated_table', 'com.my-namespace.Generated'])
    files = Dir['db/migrate/*.rb']
    expect(files.length).to eq(1)
    results = <<~MIGRATION
      class CreateGeneratedTable < ActiveRecord::Migration[6.0]
        def up
          return if table_exists?(:generated_table)
          create_table :generated_table do |t|
            t.string :a_string
            t.integer :a_int
            t.bigint :a_long
            t.string :an_enum
            t.json :an_array
            t.json :a_map
            t.json :a_record
          end
      
          # TODO add indexes as necessary
        end
      
        def down
          return unless table_exists?(:generated_table)
          drop_table :generated_table
        end
      
      end
    MIGRATION
    expect(File.read(files[0])).to eq(results)
    model = <<~MODEL
      class GeneratedTable < ApplicationRecord
        enum an_enum: {sym1: 'sym1', sym2: 'sym2'}
      end
    MODEL
    expect(File.read('app/models/generated_table.rb')).to eq(model)
  end

end
