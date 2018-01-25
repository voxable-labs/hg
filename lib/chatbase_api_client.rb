# frozen_string_literal: true

# Client used to send metrics to Chatbase, when ENV var present
class ChatbaseAPIClient
  include HTTParty
  BASE_PATH = 'https://chatbase.com/api/facebook'

  attr_accessor :intent, :text, :not_handled

  # Sends message sent by user to Chatbase
  #
  # @param [String] message
  #   Text of user message
  #
  # @return [void]
  def send_user_message(message)
    # Format for Chatbase Facebook API
    message_received = serialize_user_message(message)
    # Post to Chatbase
    catch_errors{
      self.class.post("#{BASE_PATH}/message_received?api_key=#{ENV['CHATBASE_API_KEY']}", json_body(message_received))
    }
  end

  # Sends message sent by bot to Chatbase
  #
  # @param [String, Hash] message
  #   Message sent
  # @param [Hash] response
  #   Hash of response data from Facebook
  #
  # @return [void]
  def send_bot_message(message, response)
    # Format for Chatbase Facebook API
    message_body = serialize_bot_message(message, response)
    # Post to Chatbase
    catch_errors{
      self.class.post("#{BASE_PATH}/send_message?api_key=#{ENV['CHATBASE_API_KEY']}", json_body(message_body))
    }
  end

  private

  # Formats received message data for Chatbase Facebook API
  #
  # @param [Facebook::Incoming::Message / ::Postback] message
  #   Hash of message data
  #
  # @return [Hash]
  #   Message data formatted for Chatbase
  def serialize_user_message(message)
    message_received = {
      sender: message.sender['id'],
      recipient: message.recipient['id'],
      timestamp: message.messaging['timestamp'],
      message: {
        mid: message.try(:id),
        text: text
      },
      chatbase_fields: {
        intent: intent,
        version: ENV['CHATBASE_BOT_VERSION'],
        not_handled: not_handled
      }
    }
  end

  # Formats sent message data for Chatbase Facebook API
  #
  # @param [Hash, String] message
  #   Message text
  # @param [Hash] response
  #   Response from Facebook
  #
  # @return [Hash]
  #   Message data formatted for Chatbase
  def serialize_bot_message(message, response)
    message = message.to_json if message.is_a?(Hash)
    parsed_response = JSON.parse(response)
    message_body = {
      request_body: {
        recipient: parsed_response['recipient_id'],
        message: {
          text: text
        }
      },
      response_body: {
        recipient_id: response['recipient_id'],
        message_id: response['message_id']
      },
      chatbase_fields: {
        version: ENV['CHATBASE_BOT_VERSION']
      }
    }
  end

  # Rescue errors from HTTParty
  #
  # @return [void]
  def catch_errors
    begin
      @response = yield
    rescue HTTParty::Error => e
      connection_errors(e)
    end
  end

  # Logs connections errors rescued, does not raise error
  # Errors to be captured by preferred error tracker
  #
  # @param [error] e
  #   Error captured
  #
  # @return [void]
  def connection_errors(e)
    logger.error 'error with Chatbase API request:'
    logger.error e
    logger.error e.backtrace.join("\n")
  end

  # Generate the proper request options for a JSON request body.
  #
  # @param [Hash] body
  #   The request body.
  #
  # @return [Hash]
  #   The newly generated JSON body with headers.
  def json_body(body)
    {
      body: body.to_json,
      headers: { 'Content-Type' => 'application/json' }
    }
  end
end
