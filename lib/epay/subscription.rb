module Epay
  class Subscription
    include Model
    
    attr_accessor :card_no
    
    def self.inspectable_attributes
      %w(id created_at description)
    end
    
    def created_at
      Time.parse(data['created'])
    end
    
    def card
      # The card number can be derived from last transaction
      if transactions.any?
        transactions.last.card
      else
        Card.new({
          :exp_year   => data['expyear'].to_i,
          :exp_month  => data['expmonth'].to_i,
          :kind       => data['cardtypeid'].downcase.to_sym,
          :number     => card_no
        })
      end
    end
    
    def error
      data['error']
    end
    
    def valid?
      data['error'].nil?
    end
    
    def description
      data['description']
    end
    
    def transactions
      return [] unless data['transactionList'].present?
      
      # transactionList can be a hash or an array
      Array.wrap(data['transactionList']['TransactionInformationType']).collect do |transaction_data|
        Transaction.new(transaction_data['transactionid'].to_i, transaction_data)
      end
    end
    
    # Actions
    def reload
      response = Epay::Api.request(SUBSCRIPTION_SOAP_URL, 'getsubscriptions', :subscriptionid => id) do |response|
        # API returns a list of subscriptions
        if response.success?
          @data = response.data['subscriptionAry']['SubscriptionInformationType']
          self
        else
          raise(SubscriptionNotFound, "Couldn't find subscription with ID=#{id}")
        end
      end
    end
    
    def authorize(params = {})
      post = Api.default_post_for_params(params)

      post[:instantcapture] = params[:instant_capture] ? '1' : '0'
      
      post[:subscriptionid] = id
      
      Epay::Api.request(SUBSCRIPTION_SOAP_URL, 'authorize', post) do |response|
        if response.success?
          Transaction.find(response.data['transactionid'])
        else
          Transaction.new(nil, 'error' => response.data['pbsresponse'], 'failed' => true)
        end
      end
    end
    
    def delete
      Epay::Api.request(SUBSCRIPTION_SOAP_URL, 'deletesubscription', :subscriptionid => id).success?
    end
    
    class << self
      # Epay::Subscription.find(1234)
      def find(id)
        Subscription.new(id).reload
      end
      
      # Epay::Subscription.create(:card_no => '...', :)
      def create(params)
        params.merge!(
          :order_no => (Time.now.to_f * 10000).to_i.to_s, # Produce a unique order_no - it's not used anywhere, but ePay needs this
          :amount   => 0
        )
        
        post = Api.default_post_for_params(params).merge({
          :subscription       => 1,
          :subscriptionname   => params[:description]
        })
        
        query = Api.authorize(post)
        
        if query['accept']
          # Return the new subscriber
          subscription = new(query["subscriptionid"].to_i).reload
          
          # Set (obfuscated) card number:
          subscription.card_no = query["tcardno"]
          
          subscription
        else
          new(nil, 'error' => query["error"])
        end
      end
      
      def all
        Epay::Api.request(SUBSCRIPTION_SOAP_URL, 'getsubscriptions') do |response|
          if response.success?
            collection = []
            response.data['subscriptionAry']['SubscriptionInformationType'].each do |subscription|
              collection << new_from_data(subscription)
            end
            
            collection
          end
        end
      end
      
      def new_from_data(data)
        new(data['subscriptionid'].to_i, data)
      end
    end
  end
end