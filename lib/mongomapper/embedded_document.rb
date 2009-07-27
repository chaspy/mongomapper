require 'observer'

module MongoMapper
  module EmbeddedDocument
    class NotImplemented < StandardError; end
    
    def self.included(model)
      model.class_eval do
        extend ClassMethods
        include InstanceMethods
        
        extend Associations::ClassMethods
        include Associations::InstanceMethods
        
        include EmbeddedDocumentRailsCompatibility
        include Validatable
        include Serialization
      end
    end
    
    module ClassMethods
      def inherited(subclass)
        (@subclasses ||= []) << subclass
      end
      
      def subclasses
        @subclasses
      end
      
      def keys
        @keys ||= if parent = parent_model
          parent.keys.dup
        else
          HashWithIndifferentAccess.new
        end
      end
      
      def key(name, type, options={})        
        key = Key.new(name, type, options)
        keys[key.name] = key
        
        create_accessors_for(key)
        add_to_subclasses(name, type, options)
        apply_validations_for(key)
        create_indexes_for(key)
        
        key
      end
      
      def create_accessors_for(key)
        define_method(key.name) do
          read_attribute(key.name)
        end
        
        define_method("#{key.name}=") do |value|
          write_attribute(key.name, value)
        end
        
        define_method("#{key.name}_before_typecast") do
          read_attribute_before_typecast(key.name)
        end
      end
      
      def add_to_subclasses(name, type, options)
        return if subclasses.blank?
        
        subclasses.each do |subclass|
          subclass.key name, type, options
        end
      end
      
      def ensure_index(name_or_array, options={})
        keys_to_index = if name_or_array.is_a?(Array)
          name_or_array.map { |pair| [pair[0], pair[1]] }
        else
          name_or_array
        end
        
        collection.create_index(keys_to_index, options.delete(:unique))
      end
      
      def embeddable?
        !self.ancestors.include?(Document)
      end
      
      def parent_model
        if parent = ancestors[1]
          parent if parent.ancestors.include?(EmbeddedDocument)
        end
      end
      
    private
      def create_indexes_for(key)
        ensure_index key.name if key.options[:index]
      end
      
      def apply_validations_for(key)
        attribute = key.name.to_sym
        
        if key.options[:required]
          validates_presence_of(attribute)
        end
        
        if key.options[:unique]
          validates_uniqueness_of(attribute)
        end
        
        if key.options[:numeric]
          number_options = key.type == Integer ? {:only_integer => true} : {}
          validates_numericality_of(attribute, number_options)
        end
        
        if key.options[:format]
          validates_format_of(attribute, :with => key.options[:format])
        end
        
        if key.options[:length]
          length_options = case key.options[:length]
          when Integer
            {:minimum => 0, :maximum => key.options[:length]}
          when Range
            {:within => key.options[:length]}
          when Hash
            key.options[:length]
          end
          validates_length_of(attribute, length_options)
        end
      end
    end
    
    module InstanceMethods
      def initialize(attrs={})
        unless attrs.nil?
          initialize_associations(attrs)
          self.attributes = attrs
        end
      end
      
      def attributes=(attrs)
        return if attrs.blank?
        attrs.each_pair do |method, value|
          self.send("#{method}=", value)
        end
      end
      
      def attributes
        self.class.keys.inject(HashWithIndifferentAccess.new) do |attributes, key_hash|
          name, key = key_hash
          value = value_for_key(key)
          attributes[name] = value unless value.nil?
          attributes
        end
      end
      
      def [](name)
        read_attribute(name)
      end
      
      def []=(name, value)
        write_attribute(name, value)
      end
      
      def ==(other)
        other.is_a?(self.class) && attributes == other.attributes
      end
      
      def inspect
        attributes_as_nice_string = defined_key_names.collect do |name|
          "#{name}: #{read_attribute(name)}"
        end.join(", ")
        "#<#{self.class} #{attributes_as_nice_string}>"
      end
      
    private
      def value_for_key(key)
        if key.native?
          read_attribute(key.name)
        else
          embedded_document = read_attribute(key.name)
          embedded_document && embedded_document.attributes
        end
      end

      def read_attribute(name)
        defined_key(name).get(instance_variable_get("@#{name}"))
      end

      def read_attribute_before_typecast(name)
        instance_variable_get("@#{name}_before_typecast")
      end

      def write_attribute(name, value)
        instance_variable_set "@#{name}_before_typecast", value
        instance_variable_set "@#{name}", defined_key(name).set(value)
      end

      def defined_key(name)
        self.class.keys[name]
      end

      def defined_key_names
        self.class.keys.keys
      end

      def only_defined_keys(hash={})
        defined_key_names = defined_key_names()
        hash.delete_if { |k, v| !defined_key_names.include?(k.to_s) }
      end
      
      def embedded_association_attributes
        embedded_attributes = HashWithIndifferentAccess.new
        self.class.associations.each_pair do |name, association|
          
          if association.type == :many && association.klass.embeddable?            
            if documents = instance_variable_get(association.ivar)
              embedded_attributes[name] = documents.collect do |item|
                attributes_hash = item.attributes
                
                item.send(:embedded_association_attributes).each_pair do |association_name, association_value|
                  attributes_hash[association_name] = association_value
                end
                
                attributes_hash
              end
            end
          end
        end
        
        embedded_attributes
      end

      def initialize_associations(attrs={})
        self.class.associations.each_pair do |name, association|
          if collection = attrs.delete(name)
            send("#{association.name}=", collection)
          end
        end
      end
    end
  end
end