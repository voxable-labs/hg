module Hg
  # Error thrown when no router class exists.
  class NoRouterClassExistsError < StandardError
    def initialize
      super('No Router class exists for this bot. Define a nested class Router, or set with router=')
    end
  end

  # Error thrown when no user class exists.
  class NoUserClassExistsError < StandardError
    def initialize
      super('No User class exists for this bot. Define a global class User, or set with user_class=')
    end
  end

  module Messenger
    module Bot
      def self.included(base)
        base.extend ClassMethods
        base.chunks = []
        base.call_to_actions = []

        # TODO: Need to figure this out.
        # Since the class itself represents the bot, it must be immutable for thread-safety.
        # base.freeze
      end

      module ClassMethods
        def init
          initialize_message_handlers
          initialize_persistent_menu
          initialize_get_started_button
          initialize_greeting_text
        end

        # The Facebook Page access token
        attr_writer :access_token

        def access_token
          @access_token || ENV['FB_ACCESS_TOKEN'.freeze]
        end

        # The class representing users.
        attr_writer :user_class

        # @return [Class] The class representing bot users.
        def user_class
          @user_class ||= Kernel.const_get(:User)
        rescue NameError
          raise NoUserClassExistsError.new
        end

        attr_accessor :chunks
        attr_accessor :default_chunk
        attr_accessor :call_to_actions
        attr_accessor :image_url_base_portion

        # The class representing the router.
        attr_writer :router

        # @return [Class] The bot's router class.
        def router
          @router ||= self.const_get(:Router)
        rescue NameError
          raise NoRouterClassExistsError.new
        end

        def default(chunk)
          @default_chunk = chunk
        end

        def persistent_menu(&block)
          yield
        end

        def initialize_persistent_menu
          Facebook::Messenger::Thread.set({
            setting_type:    'call_to_actions'.freeze,
            thread_state:    'existing_thread'.freeze,
            call_to_actions: @call_to_actions
          }, access_token: access_token)
        end

        def call_to_action(text, options = {})
          call_to_action_content = {
            title: text
          }

          if options[:to]
            call_to_action_content[:type] = 'postback'.freeze
            call_to_action_content[:payload] = options[:to].to_s
          elsif options[:url]
            call_to_action_content[:type] = 'web_url'.freeze
            call_to_action_content[:url] = options[:url]
          end

          @call_to_actions << call_to_action_content
        end

        def get_started(chunk)
          @get_started_content = {
            setting_type: 'call_to_actions'.freeze,
            thread_state: 'new_thread'.freeze,
            call_to_actions: [
              {
                payload: chunk.to_s
              }
            ]
          }
        end

        def initialize_get_started_button
          Facebook::Messenger::Thread.set @get_started_content, access_token: access_token
        end

        def greeting_text(text)
          @greeting_text = text
        end

        def image_url_base(base)
          @image_url_base_portion = base
        end

        def initialize_greeting_text
          Facebook::Messenger::Thread.set({
            setting_type: 'greeting'.freeze,
            greeting: {
              text: @greeting_text
            }
          }, access_token: access_token)
        end

        def run_postback_payload(payload, recipient, context)
          # TODO: Shouldn't be constantizing user input. Need a way to sanitize this.
          # TODO: Also, use Kernel.const_get https://gist.github.com/Haniyya/0d52fb8ae4c3cb3d46a07fc4180c3303
          payload.constantize.new(recipient: recipient, context: context).deliver
        end

        # Generate a redis namespace, based on the class's name.
        #
        # @return [String] The redis namespace
        def redis_namespace
          self.to_s.tableize
        end

        # Queue a postback for processing.
        #
        # @param message [Facebook::Messenger::Incoming::Postback] The postback to be queued.
        def queue_postback(postback)
          # Grab the user's PSID.
          user_id = postback.sender['id'.freeze]
          # Pull out the raw JSON postback from the `Postback` object.
          raw_postback = postback.messaging

          # Parse the postback payload as JSON, and store it as the value of
          # the `payload` key
          raw_payload = raw_postback['postback']['payload']
          raw_postback['postback']['payload'] = JSON.parse(raw_payload)

          # Store the transformed postback on the queue
          Hg::Queues::Messenger::PostbackQueue
            .new(user_id: user_id, namespace: redis_namespace)
            .push(raw_postback)

          # Queue postback for processing.
          Hg::PostbackWorker.perform_async(user_id, redis_namespace, self.to_s)
        end

        # Queue a message for processing.
        #
        # @param message [Facebook::Messenger::Incoming::Message] The message to be queued.
        def queue_message(message)
          # Store message on this user's queue of unprocessed messages.
          user_id = message.sender['id'.freeze]
          Hg::Queues::Messenger::MessageQueue
            .new(user_id: user_id, namespace: redis_namespace)
            .push(message.messaging)

          # Queue message for processing.
          Hg::MessageWorker.perform_async(user_id, redis_namespace, self.to_s)
        end

        # Show a typing indicator to the user.
        #
        # @param recipient_id [String] The Facebook PSID of the user that will see the indicator
        def show_typing(recipient_psid)
          Facebook::Messenger::Bot.deliver({
             recipient: {id: recipient_psid},
             sender_action: 'typing_on'.freeze
           }, access_token: access_token)
        end

        # Initialize the postback and message handlers for the bot, which will
        # queue the messages for processing.
        def initialize_message_handlers
          ::Facebook::Messenger::Bot.on :postback do |postback|
            # Show a typing indicator to the user
            show_typing(postback.sender['id'.freeze])

            # TODO: Build a custom logger, make production logging optional
            # Log the postback
            Rails.logger.info "POSTBACK: #{postback.payload}"

            # Queue the postback for processing
            queue_postback(postback)
          end

          ::Facebook::Messenger::Bot.on :message do |message|
            # Show a typing indicator to the user
            show_typing(message.sender['id'.freeze])

            # TODO: Build a custom logger, make production logging optional
            # Log the message
            Rails.logger.info "MESSAGE: #{message.text}"

            # Queue the message for processing
            queue_message(message)
          end
        end
      end
    end
  end
end
