class CreateProtocolTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :protocol_templates do |t|
      t.string  :protocol_key,       null: false
      t.string  :display_name,       null: false
      t.string  :description
      t.string  :match_type,         null: false
      t.jsonb   :required_selectors, null: false, default: []
      t.integer :priority,           null: false, default: 100

      t.timestamps
    end

    add_index :protocol_templates, :protocol_key, unique: true
    add_index :protocol_templates, [ :match_type, :priority ]
  end
end
