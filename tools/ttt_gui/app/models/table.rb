require 'ttt'
require 'ttt/collector'

class Table
  attr_reader :server
  attr_reader :database
  attr_reader :name
  attr_reader :stats
  def self.find(server,db,name)
    stats={}
    TTT::TrackingTable.tables.each do |s,k|
      #stats[s]=k.find(:last, :conditions => ["server = ? and database_name = ? and table_name = ? and run_time = ?", server, db, name, TTT::Collector.get_last_run(s)])
      stats[s]=k.find(:last, :conditions => ["server = ? and database_name = ? and table_name = ?", server, db, name])
    end
    self.new(server,db,name,stats)
  end

  def get_volume
    @stats[:volume]
  end

  def get_size
    @stats[:volume].size
  end

  def get_create
    table_type == :base ? @stats[:definition].create_syntax : @stats[:view].create_syntax
  end
  def table_type
    type=:base
    if @stats[:definition].nil? and @stats[:view].nil?
      type=:unknown
    elsif @stats[:definition].nil? and !@stats[:view].nil?
      type=:view
    end
    type
  end
  private
  def initialize(server,database,name,stats)
    @server=server
    @database=database
    @name=name
    @stats=stats
  end
end