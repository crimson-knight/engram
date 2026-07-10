require "http/client"
require "json"
require "uri"

module Engram
  # Raised when `.agents/engram.yml` exists but its `embedder:` section is
  # missing a required key or otherwise can't be understood.
  class EmbedderConfigError < Exception
    # Builds a "<path>: <reason>" message so the failure points at the config file.
    def initialize(path : String, reason : String)
      super("#{path}: #{reason}")
    end
  end

  # The `embedder:` settings read from `.agents/engram.yml`:
  #
  #   embedder:
  #     url: http://localhost:11434/v1/embeddings
  #     model: nomic-embed-text
  #     api_key_env: OPENAI_API_KEY
  #
  # No config file, or a config file with no `embedder:` section, means
  # embeddings are off — the zero-config default described in docs/SPEC.md.
  struct EmbedderConfig
    getter url : String
    getter model : String
    getter api_key_env : String?

    # Builds a config from already-known fields (used directly by specs).
    def initialize(@url : String, @model : String, @api_key_env : String? = nil)
    end

    # Loads and parses *path*, returning nil if the file is absent or has no `embedder:` section.
    def self.load(path : String) : EmbedderConfig?
      return nil unless File.exists?(path)

      fields = read_section(File.read(path), path, "embedder")
      return nil unless fields

      url = fields["url"]?
      raise EmbedderConfigError.new(path, "embedder.url is required") unless url

      model = fields["model"]?
      raise EmbedderConfigError.new(path, "embedder.model is required") unless model

      new(url: url, model: model, api_key_env: fields["api_key_env"]?)
    end

    # Resolves the actual API key by reading the env var named by `api_key_env`; nil if unset or unnamed.
    def api_key : String?
      env_name = api_key_env
      env_name ? ENV[env_name]? : nil
    end

    # Reads the indented `key: value` lines nested under a top-level
    # `<name>:` header out of a flat-YAML *content* string; nil if that
    # header isn't present. Deliberately its own tiny reader (a nested
    # section, not the flat frontmatter block `MemoryFile` parses) rather
    # than a shared YAML dependency.
    private def self.read_section(content : String, path : String, name : String) : Hash(String, String)?
      lines = content.split('\n')
      header_index = lines.index { |line| line.strip == "#{name}:" }
      return nil unless header_index

      fields = {} of String => String
      index = header_index + 1
      while index < lines.size
        line = lines[index]
        break unless line.strip.empty? || line.starts_with?(' ') || line.starts_with?('\t')
        index += 1

        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?('#')

        match = /\A([A-Za-z_]+):\s*(.*)\z/.match(stripped)
        raise EmbedderConfigError.new(path, "malformed line #{stripped.inspect} under '#{name}:'") unless match
        fields[match[1]] = unquote(strip_comment(match[2]))
      end
      fields
    end

    # Strips a trailing ` # comment` from a scalar value.
    private def self.strip_comment(value : String) : String
      trimmed = value.strip
      hash_index = trimmed.index(" #")
      hash_index ? trimmed[0...hash_index].rstrip : trimmed
    end

    # Removes a matching pair of surrounding quotes from a scalar value, if present.
    private def self.unquote(value : String) : String
      if value.size >= 2 && (value[0] == '"' || value[0] == '\'') && value[-1] == value[0]
        value[1..-2]
      else
        value
      end
    end
  end

  # Computes text embeddings via an OpenAI-compatible `/v1/embeddings` HTTP
  # endpoint (Ollama, OpenAI, etc). Embeddings are entirely optional: `sync`
  # only ever gets one when the caller loaded an `EmbedderConfig`, and any
  # transport failure is warned once and swallowed so a dead endpoint never
  # blocks `sync`.
  class Embedder
    # Given (config, text), returns the embedding vector or raises. Swapped
    # for a fake in specs so no real network call is ever made in tests.
    alias Transport = (EmbedderConfig, String) -> Array(Float32)

    getter? warned : Bool
    getter dimension : Int32?

    # Builds an embedder for *config* using *transport* to actually fetch vectors.
    def initialize(@config : EmbedderConfig, &@transport : Transport)
      @warned = false
      @dimension = nil
    end

    # Builds an embedder that calls the real OpenAI-compatible HTTP endpoint in *config*.
    def self.new(config : EmbedderConfig) : Embedder
      new(config) { |cfg, text| http_transport(cfg, text) }
    end

    # Embeds *text* into a packed Float32 BLOB, or nil if embedding is
    # unavailable this sync (either the transport already failed once, or it
    # fails now). Never raises: a dead endpoint must never block `sync`.
    def embed(text : String) : Bytes?
      return nil if @warned

      begin
        vector = @transport.call(@config, text)
        @dimension = vector.size
        pack(vector)
      rescue ex
        warn_once(ex)
        nil
      end
    end

    # Packs a Float32 vector into its raw little-endian byte representation for the `embedding` BLOB column.
    private def pack(vector : Array(Float32)) : Bytes
      slice = vector.to_unsafe
      Bytes.new(slice.as(UInt8*), vector.size * 4)
    end

    # Prints a one-time warning to stderr and marks this embedder as failed for the rest of the sync.
    private def warn_once(ex : Exception) : Nil
      @warned = true
      STDERR.puts "engram: warning: embedder request failed (#{ex.message}); continuing this sync without embeddings"
    end

    # POSTs `{model, input}` to `config.url` and returns the first embedding vector from an OpenAI-shaped response.
    # Public so callers outside `sync` (e.g. the CLI's one-shot query embedding for `search`) can reuse the same transport.
    def self.http_transport(config : EmbedderConfig, text : String) : Array(Float32)
      uri = URI.parse(config.url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 10.seconds
      client.read_timeout = 10.seconds

      headers = HTTP::Headers{"Content-Type" => "application/json"}
      if key = config.api_key
        headers["Authorization"] = "Bearer #{key}"
      end

      body = {model: config.model, input: text}.to_json
      response = client.post(uri.request_target, headers: headers, body: body)
      raise "embedder endpoint returned HTTP #{response.status_code}" unless response.status_code == 200

      JSON.parse(response.body)["data"][0]["embedding"].as_a.map(&.as_f.to_f32)
    ensure
      client.try(&.close)
    end
  end
end
