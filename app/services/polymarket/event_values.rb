# frozen_string_literal: true

module Polymarket
  module EventValues
    module_function

    def bytes32(value)
      return nil if value.nil?

      if value.is_a?(String) && value.encoding == Encoding::ASCII_8BIT && value.bytesize == 32
        return "0x#{value.unpack1('H*')}"
      end

      str = value.to_s.strip
      return nil if str.blank?

      candidate = str.start_with?("0x", "0X") ? str : "0x#{str}"
      candidate.downcase
    end

    def integer(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)

      str = value.to_s
      return nil if str.empty?

      if str.start_with?("0x", "0X")
        str.sub(/\A0x/i, "").to_i(16)
      else
        Integer(str, 10)
      end
    rescue ArgumentError
      nil
    end

    def boolean(value)
      return value if value == true || value == false
      return nil if value.nil?

      value.to_s == "true"
    end

    def truncate(value)
      return "(unknown)" if value.blank?

      str = value.to_s
      return str if str.length <= 14

      "#{str[0..7]}...#{str[-4..]}"
    end
  end
end
