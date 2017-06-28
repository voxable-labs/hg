module Hg
  # Handles processing messages. A message is any inbound, freeform text from
  # any platform.
  class MessageWorker < Workers::Base
    # TODO: Make number of retries configurable.
    sidekiq_options retry: 1

    # Process an inbound message.
    #
    # @param user_id [String, Integer] The ID representing the user on this
    #   platform
    # @param redis_namespace [String] The redis namespace under which the
    #   message to process is nested.
    # @param bot_class_name [String] The string version of the bot's class name
    #
    # @return [void]
    def perform(user_id, redis_namespace, bot_class_name)
      # Retrieve the latest message for this user.
      raw_message = pop_raw_message(user_id, redis_namespace)

      # Do nothing if no message available. This could be due to multiple
      # execution on the part of Sidekiq. This ensures idempotence. We loop
      # here to ensure that this worker attempts to drain the queue for
      # the user.
      until raw_message.empty?
        # Instantiate a message object with the raw message from the queue.
        message = Facebook::Messenger::Incoming::Message.new(raw_message)

        # Locate the class representing the bot.
        bot = Kernel.const_get(bot_class_name)

        # Fetch the User representing the message's sender.
        # TODO: pass in a `user_id_field` to indicate how to find user in order to
        # make this platform agnostic
        user = find_bot_user(bot, user_id)

        # If the message is a quick reply...
        if quick_reply_payload = message.quick_reply
          # Parse the JSON from the payload.
          payload = JSON.parse(quick_reply_payload)
          # ...build a request object from the payload.
          request = build_payload_request(payload, user)
        # If the message has attachments.
        elsif message.attachments
          attachment = message.attachments.first

          # If the attachment is coordinates.
          if attachment['type'] == 'location'
            # Generate a coordinates request with lat/long as parameters.
            request = Hg::Request.new(
              user:       user,
              message:    message,
              intent:     Hg::InternalActions::HANDLE_COORDINATES,
              action:     Hg::InternalActions::HANDLE_COORDINATES,
              parameters: {
                lat:   attachment['payload']['coordinates']['lat'],
                long:  attachment['payload']['coordinates']['long']
              }
            )
          else
            # TODO: What should we do if attachments aren't recognized?
          end
        # If the user is in the middle of a dialog...
        elsif user.context[:dialog_handler]
          request = build_dialog_request(user, message)
        # If the message is text...
        else
          begin
            # ...send the message to API.ai for NLU.
            nlu_response = ApiAiClient.new(user.api_ai_session_id).query(message.text)
          rescue Hg::ApiAiClient::QueryError => e
            # TODO: High - what should be the general method for reporting errors to the user?
          else
            # Drop any params that weren't recognized.
            params = nlu_response[:parameters].reject { |k, v| v.blank? }

            # Build a request.
            request = build_request(message, nlu_response, params, user)
          end
        end

        # Send the request to the bot's router.
        bot.router.handle(request) if request

        # Attempt to pop another message from the queue for processing.
        raw_message = pop_raw_message(user_id, redis_namespace)
      end
    end

    private

    # Generate a new request for this message.
    #
    # @param message [Facebook::Messenger::Incoming::Message] The incoming message.
    # @param nlu_response [Hash] The API.ai query response.
    # @param params [Hash] The parsed entities for the request.
    # @param user [Object] The user that sent the message.
    #
    # @return [Hg::Request] The generated request.
    def build_request(message, nlu_response, params, user)
      Hg::Request.new(
        user:       user,
        message:    message,
        intent:     nlu_response[:intent],
        action:     nlu_response[:action] || nlu_response[:intent],
        parameters: params,
        response:   nlu_response[:response]
      )
    end

    # TODO: High - document and test
    def build_dialog_request(user, message)
      handler_name = user.context[:dialog_handler]
      parameters   = user.context[:dialog_parameters]

      # Build a request object.
      request = Hg::Request.new(
        user:       user,
        message:    message,
        intent:     handler_name,
        action:     handler_name,
        parameters: parameters,
        route: {
          controller: Kernel.const_get(user.context[:dialog_controller]),
          handler:    handler_name
        }
      )
    end

    # Pop the latest raw message from this user's queue.
    #
    # @param user_id [String, Integer] The ID representing the user on this
    #   platform
    # @param redis_namespace [String] The redis namespace under which the
    #   message to process is nested.
    #
    # @return [Hash] The latest raw message from this user's queue.
    def pop_raw_message(user_id, redis_namespace)
      pop_from_queue(
        Hg::Queues::Messenger::MessageQueue,
        user_id:   user_id,
        namespace: redis_namespace
      )
    end
  end
end
