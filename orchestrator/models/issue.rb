require 'securerandom'

class Issue < ActiveRecord::Base
  self.primary_key = :id

  before_create { self.id ||= SecureRandom.uuid }
end
