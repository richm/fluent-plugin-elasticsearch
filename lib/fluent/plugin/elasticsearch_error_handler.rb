require 'fluent/event'
require_relative 'elasticsearch_constants'

class Fluent::ElasticsearchErrorHandler
  include Fluent::ElasticsearchConstants

  class ElasticsearchVersionMismatch < StandardError; end
  class ElasticsearchError < StandardError; end

  def initialize(plugin)
    @plugin = plugin
  end

  def handle_error(response, tag, chunk, bulk_message_count)
    if bulk_message_count != response['items'].length
      raise ElasticsearchError, "The number of records submitted do not match the number returned. Unable to process bulk response"
    end
    retry_stream = Fluent::MultiEventStream.new
    stats = Hash.new(0)
    meta = {}
    header = {}
    chunk.msgpack_each do |rawrecord, time|
      bulk_message = ''
      next unless rawrecord.is_a? Hash
      begin
        # we need a deep copy for process_message to alter
        processrecord = Marshal.load(Marshal.dump(rawrecord))
        @plugin.process_message(tag, meta, header, time, processrecord, bulk_message)
      rescue => e
        stats[:bad_chunk_record] += 1
        next
      end
      item = response['items'].shift
      if item.has_key?(@plugin.write_operation)
        write_operation = @plugin.write_operation
      elsif INDEX_OP == @plugin.write_operation && item.has_key?(CREATE_OP)
        write_operation = CREATE_OP
      else
        # When we don't have an expected ops field, something changed in the API
        # expected return values (ES 2.x)
        stats[:errors_bad_resp] += 1
        next
      end
      if item[write_operation].has_key?('status')
        status = item[write_operation]['status']
      else
        # When we don't have a status field, something changed in the API
        # expected return values (ES 2.x)
        stats[:errors_bad_resp] += 1
        next
      end
      case
      when [200, 201].include?(status)
        stats[:successes] += 1
      when CREATE_OP == write_operation && 409 == status
        stats[:duplicates] += 1
      when 400 == status
        stats[:bad_argument] += 1
        @plugin.router.emit_error_event(tag, time, rawrecord, '400 - Rejected by Elasticsearch')
      else
        if item[write_operation].has_key?('error') && item[write_operation]['error'].has_key?('type')
          type = item[write_operation]['error']['type']
          stats[type] += 1
          retry_stream.add(time, rawrecord)
        else
          # When we don't have a type field, something changed in the API
          # expected return values (ES 2.x)
          stats[:errors_bad_resp] += 1
          @plugin.router.emit_error_event(tag, time, rawrecord, status.to_s + '- No error type provided in the response')
        end
      end
    end
    @plugin.log.on_debug do
      msg = ["Indexed (op = #{@plugin.write_operation})"]
      stats.each_pair { |key, value| msg << "#{value} #{key}" }
      @plugin.log.debug msg.join(', ')
    end
    raise Fluent::ElasticsearchOutput::RetryStreamError.new(retry_stream) if not retry_stream.empty?
  end
end
