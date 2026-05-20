require 'securerandom'

class Issue < ActiveRecord::Base
  self.primary_key = :id

  belongs_to :project, optional: true

  before_create { self.id ||= SecureRandom.uuid }
end
