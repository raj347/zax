require 'mailbox'
class CommandController < ApplicationController

public
def process_cmd
  @body = request.body.read MAX_COMMAND_BODY # 100kb
  lines = _check_body_lines @body, 3, 'process command'
  @hpk = _get_hpk lines[0]
  _load_keys
  nonce = _check_nonce b64dec lines[1]
  ctext = b64dec lines[2]
  data = _decrypt_data nonce, ctext
  mailbox = Mailbox.new @hpk
  rsp_nonce = _make_nonce
  # === Process command ===
  case data[:cmd]
  when 'upload'
    hpkto = b64dec data[:to]
    mbx = Mailbox.new hpkto
    mbx.store @hpk,rsp_nonce, data[:payload]
    render nothing: true, status: :ok

  when 'count'
    data = { }
    data[:count] = mailbox.count
    enc_nonce = b64enc rsp_nonce
    enc_data = _encrypt_data rsp_nonce,data
    render text:"#{enc_nonce}\n#{enc_data}", status: :ok

  when 'download'
    count = mailbox.count > MAX_ITEMS ? MAX_ITEMS : mailbox.count
    start = data[:start] || 0
    raise "Bad download start position" unless start>=0 or start<mailbox.count
    payload = mailbox.read_all start,count
    payload = _process_payload(payload)
    enc_nonce = b64enc rsp_nonce
    enc_payload = _encrypt_data rsp_nonce,payload
    render text:"#{enc_nonce}\n#{enc_payload}", status: :ok

  when 'delete'
    for id in data[:payload]
      mailbox.delete_by_id id
    end
    # TODO: respond with encrypted count (same as cmd='count')
    render nothing: true, status: :ok
  end
  # === Error handling ===
  rescue RbNaCl::CryptoError => e
    _report_NaCl_error e
  rescue ZAXError => e
    e.http_fail
  rescue => e
    _report_error e
end

# === Helper Functions ===
private

def _load_keys
  logger.info "#{INFO_GOOD} Reading client session key for hpk #{b64enc @hpk}"
  @session_key = Rails.cache.read("session_key_#{@hpk}")
  @client_key = Rails.cache.read("client_key_#{@hpk}")
  raise HPK_keys.new(self,@hpk), "No cached session key" unless @session_key
  raise HPK_keys.new(self,@hpk), "No cached client key"  unless @client_key
end

def _check_body(body)
  lines = super body
  unless lines and lines.count==3 and
    lines[0].length==TOKEN_B64 and
    lines[1].length==NONCE_B64
    raise "process_cmd malformed body, #{ lines ? lines.count : 0} lines"
  end
  return lines
end

def _decrypt_data(nonce,ctext)
  box = RbNaCl::Box.new(@client_key,@session_key)
  d = JSON.parse box.decrypt(nonce,ctext)
  d = d.reduce({}) { |h,(k,v)| h[k.to_sym]=v; h }
  puts d[:payload]
  _check_command d
end

def _encrypt_data(nonce,data)
  box = RbNaCl::Box.new(@client_key,@session_key)
  b64enc box.encrypt(nonce,data.to_json)
end

def _rand_str(min,size)
  (b64enc rand_bytes min+rand(size)).gsub '=',''
end

def _check_command(data)
  all = %w[count upload download delete]

  raise "command_controller: missing command" unless data[:cmd]
  raise "command_controller: unknown command #{data[:cmd]}" unless all.include? data[:cmd]

  if data[:cmd] == 'upload'
    raise "command_controller: no destination HPK in upload" unless data[:to]
    hpk_dec = b64dec data[:to]
    _check_hpk hpk_dec
    raise "command_controller: no payload in upload" unless data[:payload]
  end

  if data[:cmd] == 'delete'
    raise "command_controller: no ids to delete" unless data[:payload]
  end

  return data
end

# all of the messages in the mailbox are read out as an array
def _process_payload(messages)
  payload_ary = []
  messages.each do | message|
    payload = {}
    payload[:data] = message[:data]
    payload[:time] = message[:time]
    payload[:from] = b64enc message[:from]
    payload[:nonce] = b64enc message[:nonce]
    payload_ary.push payload
  end
  payload_ary
end

def _report_error(e)
  logger.warn "#{WARN} Process command aborted:\n#{@body}\n#{EXPT} #{e}"
  head :precondition_failed, x_error_details:
    "Can't process command: #{e.message}"
end
end