# -*- coding: utf-8 -*-

module RIMS
  module Protocol
    def quote(s)
      case (s)
      when /"/, /\n/
        "{#{s.bytesize}}\r\n" + s
      else
        '"' + s + '"'
      end
    end
    module_function :quote

    def compile_wildcard(pattern)
      src = '^'
      src << pattern.gsub(/.*?[*%]/) {|s| Regexp.quote(s[0..-2]) + '.*' }
      src << Regexp.quote($') if $'
      src << '$'
      Regexp.compile(src)
    end
    module_function :compile_wildcard

    def read_line(input)
      line = input.gets or return
      line.chomp!("\n")
      line.chomp!("\r")
      scan_line(line, input)
    end
    module_function :read_line

    def scan_line(line, input)
      atom_list = line.scan(/[\[\]()]|".*?"|[^\[\]()\s]+/).map{|s| s.sub(/^"/, '').sub(/"$/, '') }
      if (atom_list[-1] =~ /^{\d+}$/) then
	next_size = $&[1..-2].to_i
	atom_list[-1] = input.read(next_size) or raise 'unexpected client close.'
        next_atom_list = read_line(input) or raise 'unexpected client close.'
	atom_list += next_atom_list
      end

      atom_list
    end
    module_function :scan_line

    def parse(atom_list, last_atom=nil)
      syntax_list = []
      while (atom = atom_list.shift)
        case (atom)
        when last_atom
          break
        when '('
          syntax_list.push([ :group ] + parse(atom_list, ')'))
        when '['
          syntax_list.push([ :block ] + parse(atom_list, ']'))
        else
          syntax_list.push(atom)
        end
      end

      if (atom == nil && last_atom != nil) then
        raise 'syntax error.'
      end

      syntax_list
    end
    module_function :parse

    def read_command(input)
      while (atom_list = read_line(input))
        if (atom_list.empty?) then
          next
        end
        if (atom_list.length < 2) then
          raise 'need for tag and command.'
        end
        if (atom_list[0] =~ /^[*+]/) then
          raise "invalid command tag: #{atom_list[0]}"
        end
        return parse(atom_list)
      end

      nil
    end
    module_function :read_command
  end

  class ProtocolDecoder
    def initialize(mail_store, logger)
      @st = mail_store
      @logger = logger
      @username = nil
      @password = nil
      @is_auth = false
      @folder = nil
    end

    attr_writer :username
    attr_writer :password

    def auth?
      @is_auth
    end

    def selected?
      @folder != nil
    end

    def protect_error(tag)
      begin
        yield
      rescue
        @logger.error('internal server error.')
        @logger.error($!)
        [ "#{tag} BAD internal server error" ]
      end
    end
    private :protect_error

    def protect_auth(tag)
      protect_error(tag) {
        if (auth?) then
          yield
        else
          [ "#{tag} NO no authentication" ]
        end
      }
    end
    private :protect_auth

    def protect_select(tag)
      protect_auth(tag) {
        if (selected?) then
          yield
        else
          [ "#{tag} NO no selected" ]
        end
      }
    end
    private :protect_select

    def capability(tag)
      [ '* CAPABILITY IMAP4rev1',
        "#{tag} OK CAPABILITY completed"
      ]
    end

    def noop(tag)
      res = []
      if (auth? && selected?) then
        @folder.reload if @folder.updated?
        res << "* #{@st.mbox_msgs(@folder.id)} EXISTS"
        res << "* #{@st.mbox_flags(@folder.id, 'resent')} RECENTS"
      end
      res << "#{tag} OK NOOP completed"
    end

    def logout(tag)
      @folder = nil
      @is_auth = false
      res = []
      res << '* BYE server logout'
      res << "#{tag} OK LOGOUT completed"
    end

    def authenticate(tag, auth_name)
      [ "#{tag} NO no support mechanism" ]
    end

    def login(tag, username, password)
      res = []
      if (username == @username && password == @password) then
        @is_auth = true
        res << "#{tag} OK LOGIN completed"
      else
        res << "#{tag} NO failed to login"
      end
    end

    def select(tag, mbox_name)
      protect_auth(tag) {
        res = []
        @folder = nil
        if (id = @st.mbox_id(mbox_name)) then
          @folder = @st.select_mbox(id)
          all_msgs = @st.mbox_msgs(@folder.id)
          recent_msgs = @st.mbox_flags(@folder.id, 'recent')
          unseen_msgs = all_msgs - @st.mbox_flags(@folder.id, 'unseen')
          res << "* #{all_msgs} EXISTS"
          res << "* #{recent_msgs} RECENT"
          res << "* [UNSEEN #{unseen_msgs}]"
          res << "* [UIDVALIDITY #{@folder.id}]"
          res << "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)"
          res << "#{tag} OK [READ-WRITE] SELECT completed"
        else
          res << "#{tag} NO not found a mailbox"
        end
      }
    end

    def examine(tag, mbox_name)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def create(tag, mbox_name)
      protect_auth(tag) {
        res = []
        if (@st.mbox_id(mbox_name)) then
          res << "#{tag} NO duplicated mailbox"
        else
          @st.add_mbox(mbox_name)
          res << "#{tag} OK CREATE completed"
        end
      }
    end

    def delete(tag, mbox_name)
      protect_auth(tag) {
        res = []
        if (id = @st.mbox_id(mbox_name)) then
          if (id != @st.mbox_id('INBOX')) then
            @st.del_mbox(id)
            res << "#{tag} OK DELETE completed"
          else
            res << "#{tag} NO not delete inbox"
          end
        else
          res << "#{tag} NO not found a mailbox"
        end
      }
    end

    def rename(tag, src_name, dst_name)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def subscribe(tag, mbox_name)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def unsubscribe(tag, mbox_name)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def list(tag, ref_name, mbox_name)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def lsub(tag, ref_name, mbox_name)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def status(tag, mbox_name, data_item_group)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def append(tag, mbox_name, *opt_args, msg_text)
      protect_auth(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def check(tag)
      protect_select(tag) {
        @st.sync
        [ "#{tag} OK CHECK completed" ]
      }
    end

    def close(tag)
      protect_select(tag) {
        @st.sync
        @folder = nil
        [ "#{tag} OK CLOSE completed" ]
      }
    end

    def expunge(tag)
      protect_select(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def search(tag, *cond_args, uid: false)
      protect_select(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def fetch(tag, msg_set, data_item_group, uid: false)
      protect_select(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def store(tag, msg_set, data_item_name, data_item_value, uid: false)
      protect_select(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def copy(tag, msg_set, mbox_name, uid: false)
      protect_select(tag) {
        [ "#{tag} BAD not implemented" ]
      }
    end

    def self.repl(decoder, input, output, logger)
      loop do
        begin
          atom_list = Protocol.read_command(input)
        rescue
          logger.error('invalid client command.')
          logger.error($!)
          next
        end

        tag, command, *opt_args = atom_list
        logger.info("client command: #{command}")
        logger.debug("client command parameter: #{opt_args.inspect}") if logger.debug?

        begin
          case (command.upcase)
          when 'CAPABILITY'
            res = decoder.capability(tag, *opt_args)
          when 'NOOP'
            res = decoder.noop(tag, *opt_args)
          when 'LOGOUT'
            res = decoder.logout(tag, *opt_args)
          when 'AUTHENTICATE'
            res = decoder.authenticate(tag, *opt_args)
          when 'LOGIN'
            res = decoder.login(tag, *opt_args)
          when 'SELECT'
            res = decoder.select(tag, *opt_args)
          when 'EXAMINE'
            res = decoder.examine(tag, *opt_args)
          when 'CREATE'
            res = decoder.create(tag, *opt_args)
          when 'DELETE'
            res = decoder.delete(tag, *opt_args)
          when 'RENAME'
            res = decoder.rename(tag, *opt_args)
          when 'SUBSCRIBE'
            res = decoder.subscribe(tag, *opt_args)
          when 'UNSUBSCRIBE'
            res = decoder.unsubscribe(tag, *opt_args)
          when 'LIST'
            res = decoder.list(tag, *opt_args)
          when 'LSUB'
            res = decoder.lsub(tag, *opt_args)
          when 'STATUS'
            res = decoder.status(tag, *opt_args)
          when 'APPEND'
            res = decoder.append(tag, *opt_args)
          when 'CHECK'
            res = decoder.check(tag, *opt_args)
          when 'CLOSE'
            res = decoder.close(tag, *opt_args)
          when 'EXPUNGE'
            res = decoder.expunge(tag, *opt_args)
          when 'SEARCH'
            res = decoder.search(tag, *opt_args)
          when 'FETCH'
            res = decoder.fetch(tag, *opt_args)
          when 'STORE'
            res = decoder.store(tag, *opt_args)
          when 'COPY'
            res = decoder.copy(tag, *opt_args)
          when 'UID'
            unless (opt_args.empty?) then
              uid_command, *uid_args = opt_args
              logger.info("uid command: #{uid_command}")
              logger.debug("uid parameter: (#{uid_args.join(' ')})") if logger.debug?
              case (uid_command.upcase)
              when 'SEARCH'
                res = decoder.search(tag, *opt_args, uid: true)
              when 'FETCH'
                res = decoder.fetch(tag, *opt_args, uid: true)
              when 'STORE'
                res = decoder.store(tag, *opt_args, uid: true)
              when 'COPY'
                res = decoder.copy(tag, *opt_args, uid: true)
              else
                logger.error("unknown uid command: #{uid_command}")
                res = [ "#{tag} BAD unknown uid command" ]
              end
            else
              logger.error('empty uid parameter.')
              res = [ "#{tag} BAD empty uid parameter" ]
            end
          else
            logger.error("unknown command: #{command}")
            res = [ "#{tag} BAD unknown command" ]
          end
        rescue ArgumentError
          logger.error('invalid command parameter.')
          logger.error($!)
          res = [ "#{tag} BAD invalid command parameter" ]
        rescue
          logger.error('internal server error.')
          logger.error($!)
          res = [ "#{tag} BAD internval server error" ]
        end

        logger.info("server response: #{res[-1]}")
        for line in res
          logger.debug(line) if logger.debug?
          output << line << "\r\n"
        end
        output.flush

        if (command.upcase == 'LOGOUT') then
          break
        end
      end

      nil
    end
  end
end

# Local Variables:
# mode: Ruby
# indent-tabs-mode: nil
# End:
