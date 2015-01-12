require 'msgpack'
require 'openssl'
require 'openssl/digest'
require 'tarantool16/consts'
require_relative 'response'

module Tarantool16
  module Connection
    class Error < ::StandardError; end
    class CouldNotConnect < Error; end
    class Disconnected < Error; end
    class UnexpectedResponse < Error; end

    module Common
      attr :host, :user
      def _init_common(host, opts)
        @host = host
        @user = opts[:user]
        if opts[:password]
          @passwd = ::OpenSSL::Digest::SHA1.digest(opts[:password])
        end
        @p = MessagePack::Packer.new
        @u = MessagePack::Unpacker.new
        @s = 0
      end

      def next_sync
        @s = @s % 0x3fffffff + 1
      end

      def format_request(code, sync, body)
        @p.write(0x01020304).
          write_map_header(2).
          write(IPROTO_CODE).write(code).
          write(IPROTO_SYNC).write(sync).
          write(body)
        sz = @p.size - 5
        str = @p.to_s
        @p.clear
        # fix bigendian size
        str.setbyte(4, sz)
        str.setbyte(3, sz>>8)
        str.setbyte(2, sz>>16)
        str.setbyte(1, sz>>24)
        str
      end

      def format_authenticate(user, pass1, salt)
        pass2 = ::OpenSSL::Digest::SHA1.digest(pass1)
        scramble = ::OpenSSL::Digest::SHA1.new(salt).update(pass2).digest
        pints = pass1.unpack('L*')
        sints = scramble.unpack('L*')
        pints.size.times{|i| sints[i] ^= pints[i] }
        format_request(REQUEST_TYPE_AUTHENTICATE, {
          IPROTO_USER_NAME => user,
          IPROTO_TUPLE => [ 'chap-sha1', pints.pack('L*') ]
        })
      end

      def parse_greeting(greeting)
        @greeting = greeting[0, 64]
        @salt = greeting[64, 44].unpack('m')[0]
      end

      def parse_size(str)
        @u.feed(str)
        n = @u.read
        unless Integer === n
          return UnexpectedResponse.new("wanted response size, got #{n.inspect}")
        end
        n
      rescue ::MessagePack::UnpackError, ::MessagePack::TypeError => e
        e
      end

      def parse_reponse(str)
        sync = nil
        @u.feed(str)
        n = @u.read_map_header
        while n > 0
          cd = @u.read
          vl = @u.read
          case cd
          when IPROTO_SYNC
            sync = vl
          when IPROTO_CODE
            code = vl
          end
          n -= 1
        end
        if sync == nil
          return Response.new(nil, UnexpectedResponse, "Mailformed response: no sync")
        elsif code == nil
          return Response.new(nil, UnexpectedResponse, "Mailformed response: no code for sync=#{sync}")
        end
        unless @u.buffer.empty?
          n = @u.read_map_header
          while n > 0
            cd = @u.read
            vl = @u.read
            body = vl if cd == IPROTO_DATA || cd == IPROTO_ERROR
            n -= 1
          end
        else
          body = nil
        end
        Response.new(sync, code, body)
      rescue ::MessagePack::UnpackError, ::MessagePack::TypeError => e
        Response.new(sync, e, nil)
      end

      def host_port
        h, p = @host.split(':')
        [h, p.to_i]
      end

      def _insert(space_no, tuple, cb)
        req = {IPROTO_SPACE_ID => space_no,
               IPROTO_TUPLE => tuple}
        send_request(REQUEST_TYPE_INSERT, req, cb)
      end

      def _replace(space_no, tuple, cb)
        req = {IPROTO_SPACE_ID => space_no,
               IPROTO_TUPLE => tuple}
        send_request(REQUEST_TYPE_REPLACE, req, cb)
      end

      def _delete(space_no, index_no, key, cb)
        req = {IPROTO_SPACE_ID => space_no,
               IPROTO_INDEX_ID => index_no,
               IPROTO_KEY => key}
        send_request(REQUEST_TYPE_DELETE, req, cb)
      end

      def _select(space_no, index_no, key, offset, limit, iterator, cb)
        iterator ||= ::Tarantool16::ITERATOR_EQ
        unless Integer === iterator
          unless it = ::Tarantool16::Iterators[iterator]
            raise "Unknown iterator #{iterator.inspect}"
          end
          iterator = it
        end
        req = {IPROTO_SPACE_ID => space_no,
               IPROTO_INDEX_ID => index_no,
               IPROTO_KEY => key || [],
               IPROTO_OFFSET => offset,
               IPROTO_LIMIT => limit,
               IPROTO_ITERATOR => iterator}
        send_request(REQUEST_TYPE_SELECT, req, cb)
      end

      def _update(space_no, index_no, key, ops, cb)
        req = {IPROTO_SPACE_ID => space_no,
               IPROTO_INDEX_ID => index_no,
               IPROTO_KEY => key,
               IPROTO_TUPLE => ops}
        send_request(REQUEST_TYPE_UPDATE, req, cb)
      end

      def _call(name, args, cb)
        req = {IPROTO_FUNCTION_NAME => name,
               IPROTO_TUPLE => args}
        send_request(REQUEST_TYPE_CALL, req, cb)
      end

      REQ_EMPTY = {}.freeze
      def _ping(cb)
        send_request(REQUEST_TYPE_PING, REQ_EMPTY, cb)
      end
    end
  end
end
