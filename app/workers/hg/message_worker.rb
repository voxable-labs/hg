module Hg
  # Handles processing messages. A message is any inbound, freeform text from
  # any platform.
  class MessageWorker < Workers::Base
    # TODO: Make number of retries configurable.
    sidekiq_options retry: 1

    # Process an inbound message.
    #
    # @param user_id [String, Integer]
    #   The ID representing the user on this platform.
    # @param redis_namespace [String]
    #   The redis namespace under which the message to process is nested.
    # @param bot_class_name [String]
    #   The string version of the bot's class name
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

        # Send to Chatbase if env var present
        if ENV['CHATBASE_API_KEY']
          chatbase_api_client.send_user_message(message)
        end
        
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
        elsif user.context[:dialog_action]
          request = build_dialog_request(user, message)

          # If the message is text...
        else
          # Parse the message.
          nlu_response, params = parse_message(message.text, user)

          # Build a request.
          request = build_request(message, nlu_response, params, user)
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
    # @param message [Facebook::Messenger::Incoming::Message]
    #   The incoming message.
    # @param nlu_response [Hash]
    #   The API.ai query response.
    # @param params [Hash]
    #   The parsed entities for the request.
    # @param user [Object]
    #   The user that sent the message.
    #
    # @return [Hg::Request]
    #   The generated request.
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

    # Pop the latest raw message from this user's queue.
    #
    # @param user_id [String, Integer]
    #   The ID representing the user on this platform.
    # @param redis_namespace [String]
    #   The redis namespace under which the message to process is nested.
    #
    # @return [Hash]
    #   The latest raw message from this user's queue.
    def pop_raw_message(user_id, redis_namespace)
      pop_from_queue(
        Hg::Queues::Messenger::MessageQueue,
        user_id:   user_id,
        namespace: redis_namespace
      )
    end

    # Build a request when the user is in the midst of a dialog prompt.
    #
    # @param [Object] user
    #   The user for this request.
    # @param [Hash] message
    #   The message for this request.
    #
    # @return [Hg::Request]
    #   The generated dialog request.
    def build_dialog_request(user, message)
      # Fetch the information from the user's context.
      action       = user.context[:dialog_action]
      parameters   = user.context[:dialog_parameters]

      # Build a request object.
      request = Hg::Request.new(
        user:       user,
        message:    message,
        intent:     action,
        action:     action,
        parameters: parameters
      )

      # Clear the user's dialog context.
      user.update_context!(dialog_action: nil)
      user.update_context!(dialog_parameters: nil)

      request
    end
  end
end
