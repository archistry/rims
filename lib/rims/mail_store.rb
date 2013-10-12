# -*- coding: utf-8 -*-

require 'set'

module RIMS
  class MailStore
    def initialize(store_dir, &block) # :yields: path
      @store_dir = store_dir
      @open_kvs = block
    end

    def open_kvs(name)
      @open_kvs.call(File.join(@store_dir, name))
    end
    private :open_kvs

    def open
      @global_db = GlobalDB.new(open_kvs('global.db')).setup
      @msg_db = MessageDB.new(open_kvs('message.db'))

      @mbox_db = {}
      @global_db.each_mbox_id do |id|
        @mbox_db[id] = MailoxDB.new(open_kvs("mbox_#{id}.db")).setup
      end

      self
    end

    def close
      @mbox_db.each_value do |db|
        db.close
      end
      @msg_db.close
      @global_db.close
      self
    end

    def sync
      @msg_db.sync
      @mbox_db.each_value do |db|
        db.sync
      end
      @global_db.sync
      self
    end

    def cnum
      @global_db.cnum
    end

    def uid
      @global_db.uid
    end

    def uidvalidity
      @global_db.uidvalidity
    end

    def add_mbox(name)
      name = 'INBOX' if (name =~ /^INBOX$/i)
      if (@global_db.mbox_id(name)) then
        raise "duplicated mailbox name: #{name}."
      end

      cnum = @global_db.cnum
      next_id = @global_db.uidvalidity

      @mbox_db[next_id] = MailboxDB.new(open_kvs("mbox_#{next_id}.db")).setup
      @mbox_db[next_id].mbox_id = next_id
      @mbox_db[next_id].mbox_name = name

      @global_db.uidvalidity = next_id + 1
      @global_db.add_mbox(next_id, name)
      @global_db.cnum = cnum + 1

      next_id
    end

    def del_mbox(id)
      cnum = @global_db.cnum

      mbox_db = @mbox_db[id] or raise "not found a mailbox: #{id}."
      mbox_db.each_msg_id do |msg_id|
        @msg_db.del_msg_mbox(msg_id, id)
      end
      mbox_db.close

      name = @global_db.del_mbox(id) or raise "internal error: not found a mailbox: #{id}"
      @global_db.cnum = cnum + 1

      name
    end

    def mbox_name(id)
      @global_db.mbox_name(id)
    end

    def mbox_id(name)
      name = 'INBOX' if (name =~ /^INBOX$/i)
      @global_db.mbox_id(name)
    end

    def each_mbox_id
      return enum_for(:each_mbox_id) unless block_given?
      @global_db.each_mbox_id do |id|
        yield(id)
      end
      self
    end

    def mbox_msgs(id)
      mbox_db = @mbox_db[id] or raise "not found a mailbox: #{id}."
      mbox_db.msgs
    end

    def mbox_flags(id, name)
      mbox_db = @mbox_db[id] or raise "not found a mailbox: #{id}."
      mbox_db.flags(name)
    end

    def add_msg(mbox_id, msg_text, msg_date=Time.now)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."

      cnum = @global_db.cnum
      next_id = @global_db.uid

      @global_db.uid = next_id + 1
      @msg_db.add_msg(next_id, msg_text, msg_date)
      @msg_db.add_msg_mbox(next_id, mbox_id)
      @msg_db.set_msg_flag(next_id, 'seen', false)
      @msg_db.set_msg_flag(next_id, 'answered', false)
      @msg_db.set_msg_flag(next_id, 'flagged', false)
      @msg_db.set_msg_flag(next_id, 'draft', false)
      mbox_db.add_msg(next_id)

      @global_db.cnum = cnum + 1

      set_msg_flag(mbox_id, next_id, 'recent', true)

      next_id
    end

    def copy_msg(msg_id, dest_mbox_id)
      mbox_db = @mbox_db[dest_mbox_id] or raise "not found a mailbox: #{dest_mbox_id}."

      cnum = @global_db.cnum

      @msg_db.add_msg_mbox(msg_id, dest_mbox_id)
      mbox_db.add_msg(msg_id)

      for name in %w[ seen answered flagged draft recent ]
        if (@msg_db.msg_flag(msg_id, name)) then
          mbox_db.flags_increment(name)
        end
      end

      @global_db.cnum = cnum + 1

      self
    end

    def msg_text(mbox_id, msg_id)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."
      @msg_db.msg_text(msg_id) if (mbox_db.exist_msg? msg_id)
    end

    def msg_date(mbox_id, msg_id)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."
      @msg_db.msg_date(msg_id) if (mbox_db.exist_msg? msg_id)
    end

    def msg_flag(mbox_id, msg_id, name)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."
      unless (mbox_db.exist_msg? msg_id) then
        raise "not found a message <#{msg_id}> at mailbox <#{mbox_id}>."
      end

      case (name)
      when 'recent', 'seen', 'answered', 'flagged', 'draft'
        @msg_db.msg_flag(msg_id, name)
      when 'deleted'
        mbox_db.msg_flag_del(msg_id)
      else
        raise "unnown flag name: #{name}"
      end
    end

    def set_msg_flag(mbox_id, msg_id, name, value)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."
      unless (mbox_db.exist_msg? msg_id) then
        raise "not found a message <#{msg_id}> at mailbox <#{mbox_id}>."
      end

      cnum = @global_db.cnum

      case (name)
      when 'recent', 'seen', 'answered', 'flagged', 'draft'
        @msg_db.set_msg_flag(msg_id, name, value)
        for id in @msg_db.msg_mboxes(msg_id)
          if (value) then
            @mbox_db[id].flags_increment(name)
          else
            @mbox_db[id].flags_decrement(name)
          end
        end
      when 'deleted'
        mbox_db.set_msg_flag_del(msg_id, value)
        if (value) then
          mbox_db.flags_increment(name)
        else
          mbox_db.flags_decrement(name)
        end
      else
        raise "unnown flag name: #{name}"
      end

      @global_db.cnum = cnum + 1

      self
    end

    def each_msg_id(mbox_id)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."
      return enum_for(:each_msg_id, mbox_id) unless block_given?
      mbox_db.each_msg_id do |id|
        yield(id)
      end
      self
    end

    def expunge_mbox(mbox_id)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."

      cnum = @global_db.cnum

      msg_list = mbox_db.each_msg_id.find_all{|id| mbox_db.msg_flag_del(id) }
      for id in msg_list
        for name in %w[ seen answered flagged deleted draft recent ]
          if (msg_flag(mbox_id, id, name)) then
            mbox_db.flags_decrement(name)
          end
        end
        mbox_db.expunge_msg(id)
      end

      @global_db.cnum = cnum + 1

      self
    end

    def select_mbox(mbox_id)
      mbox_db = @mbox_db[mbox_id] or raise "not found a mailbox: #{mbox_id}."
      MailFolder.new(mbox_id, self)
    end
  end

  class MailFolder
    MessageStruct = Struct.new(:id, :num)

    def initialize(mbox_id, mail_store)
      @id = mbox_id
      @st = mail_store
      reload
    end

    def reload
      @cnum = @st.cnum
      msg_id_list = @st.each_msg_id(@id).to_a
      msg_id_list.sort
      @msg_list = msg_id_list.zip(1..(msg_id_list.length)).map{|id, num| MessageStruct.new(id, num) }
      self
    end

    def updated?
      @st.cnum > @cnum
    end

    attr_reader :id
    attr_reader :msg_list

    def parse_msg_set(msg_set_desc, uid: false)
      if (uid) then
        last_number = @msg_list[-1].id
      else
        last_number = @msg_list[-1].num
      end
      self.class.parse_msg_set(msg_set_desc, last_number)
    end

    def self.parse_msg_seq(msg_seq_desc, last_number)
      case (msg_seq_desc)
      when /^(\d+|\*)$/
        msg_seq_pair = [ $&, $& ]
      when /^(\d+|\*):(\d+|\*)$/
        msg_seq_pair = [ $1, $2 ]
      else
        raise "invalid message sequence format: #{msg_seq_desc}"
      end

      msg_seq_pair.map!{|num|
        case (num)
        when '*'
          last_number
        else
          n = num.to_i
          if (n < 1) then
            raise "out of range of message sequence number: #{msg_seq_desc}"
          end
          n
        end
      }

      Range.new(msg_seq_pair[0], msg_seq_pair[1])
    end

    def self.parse_msg_set(msg_set_desc, last_number)
      msg_set = [].to_set
      msg_set_desc.split(/,/).each do |msg_seq_desc|
        msg_range = parse_msg_seq(msg_seq_desc, last_number)
        msg_range.step do |n|
          msg_set << n
        end
      end

      msg_set
    end
  end
end

# Local Variables:
# mode: Ruby
# indent-tabs-mode: nil
# End:
