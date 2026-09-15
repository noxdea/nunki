# frozen_string_literal: true

require "json"

module Nunki
  module Protocol
    MAX_DEPTH = 32
    MAX_COLLECTION = 10_000
    MAX_STRING = 1_048_576

    module_function

    def json(value, depth = 0)
      raise ProtocolError, "JSON nesting exceeds #{MAX_DEPTH}" if depth > MAX_DEPTH

      case value
      when nil, true, false, Integer
        value
      when Float
        raise ProtocolError, "JSON number must be finite" unless value.finite?
      when String
        string(value, "JSON string")
      when Array
        collection(value, "JSON array").each { |item| json(item, depth + 1) }
      when Hash
        object(value, "JSON object").each do |key, item|
          raise ProtocolError, "JSON object keys must be strings or symbols" unless key.is_a?(String) || key.is_a?(Symbol)
          json(item, depth + 1)
        end
      else
        raise ProtocolError, "unsupported JSON value: #{value.class}"
      end
      value
    end

    def parse(source, name = "response")
      string(source, name, max: nil)
      json(JSON.parse(source, max_nesting: MAX_DEPTH))
    rescue JSON::ParserError => error
      raise ProtocolError, "invalid #{name}: #{error.message}"
    end

    def object(value, name)
      raise ProtocolError, "#{name} must be an object" unless value.is_a?(Hash)
      raise ProtocolError, "#{name} has too many members" if value.length > MAX_COLLECTION
      value
    end

    def collection(value, name)
      raise ProtocolError, "#{name} must be an array" unless value.is_a?(Array)
      raise ProtocolError, "#{name} has too many items" if value.length > MAX_COLLECTION
      value
    end

    def string(value, name, empty: true, max: MAX_STRING)
      raise ProtocolError, "#{name} must be a string" unless value.is_a?(String)
      raise ProtocolError, "#{name} must not be empty" if !empty && value.empty?
      raise ProtocolError, "#{name} is too large" if max && value.bytesize > max
      encoded = value.encode(Encoding::UTF_8)
      raise EncodingError unless encoded.valid_encoding?
      encoded
    rescue EncodingError
      raise ProtocolError, "#{name} must be valid UTF-8"
    end

    def uint(value, name, positive: false)
      minimum = positive ? 1 : 0
      raise ProtocolError, "#{name} must be an integer >= #{minimum}" unless value.is_a?(Integer) && value >= minimum
      value
    end

    def deep_freeze(value)
      case value
      when Array then value.each { |item| deep_freeze(item) }
      when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      end
      value.freeze
    end
  end
end
