require "./spec_helper"
require "../src/engram/embedder"

private def fake_config(url : String = "http://fake.local/v1/embeddings", model : String = "fake-model",
                        api_key_env : String? = nil) : Engram::EmbedderConfig
  Engram::EmbedderConfig.new(url: url, model: model, api_key_env: api_key_env)
end

describe Engram::EmbedderConfig do
  describe ".load" do
    it "returns nil when the config file doesn't exist" do
      SpecHelper.with_tempdir do |dir|
        Engram::EmbedderConfig.load(File.join(dir, "engram.yml")).should be_nil
      end
    end

    it "returns nil when the file exists but has no embedder: section" do
      SpecHelper.with_tempdir do |dir|
        path = SpecHelper.write_file(dir, "engram.yml", "some_other_key: value\n")
        Engram::EmbedderConfig.load(path).should be_nil
      end
    end

    it "parses url, model, and api_key_env from a nested embedder: section" do
      SpecHelper.with_tempdir do |dir|
        content = <<-YAML
          embedder:
            url: http://localhost:11434/v1/embeddings
            model: nomic-embed-text
            api_key_env: OPENAI_API_KEY
          YAML
        path = SpecHelper.write_file(dir, "engram.yml", content)
        config = Engram::EmbedderConfig.load(path).not_nil!

        config.url.should eq("http://localhost:11434/v1/embeddings")
        config.model.should eq("nomic-embed-text")
        config.api_key_env.should eq("OPENAI_API_KEY")
      end
    end

    it "leaves api_key_env nil when it's absent" do
      SpecHelper.with_tempdir do |dir|
        content = <<-YAML
          embedder:
            url: http://localhost:11434/v1/embeddings
            model: nomic-embed-text
          YAML
        path = SpecHelper.write_file(dir, "engram.yml", content)
        config = Engram::EmbedderConfig.load(path).not_nil!

        config.api_key_env.should be_nil
      end
    end

    it "raises Engram::EmbedderConfigError when embedder.url is missing" do
      SpecHelper.with_tempdir do |dir|
        content = <<-YAML
          embedder:
            model: nomic-embed-text
          YAML
        path = SpecHelper.write_file(dir, "engram.yml", content)

        expect_raises(Engram::EmbedderConfigError, /url is required/) do
          Engram::EmbedderConfig.load(path)
        end
      end
    end

    it "raises Engram::EmbedderConfigError when embedder.model is missing" do
      SpecHelper.with_tempdir do |dir|
        content = <<-YAML
          embedder:
            url: http://localhost:11434/v1/embeddings
          YAML
        path = SpecHelper.write_file(dir, "engram.yml", content)

        expect_raises(Engram::EmbedderConfigError, /model is required/) do
          Engram::EmbedderConfig.load(path)
        end
      end
    end

    it "ignores keys and sections that come after the embedder: block" do
      SpecHelper.with_tempdir do |dir|
        content = <<-YAML
          embedder:
            url: http://localhost:11434/v1/embeddings
            model: nomic-embed-text
          another_section:
            unrelated: true
          YAML
        path = SpecHelper.write_file(dir, "engram.yml", content)
        config = Engram::EmbedderConfig.load(path).not_nil!

        config.model.should eq("nomic-embed-text")
      end
    end
  end

  describe "#api_key" do
    it "reads the named env var when api_key_env is set" do
      ENV["ENGRAM_SPEC_FAKE_KEY"] = "sekrit"
      config = fake_config(api_key_env: "ENGRAM_SPEC_FAKE_KEY")
      config.api_key.should eq("sekrit")
    ensure
      ENV.delete("ENGRAM_SPEC_FAKE_KEY")
    end

    it "is nil when api_key_env is unset" do
      fake_config(api_key_env: nil).api_key.should be_nil
    end
  end
end

describe Engram::Embedder do
  describe "#embed" do
    it "packs the transport's vector into a Float32 BLOB and records its dimension" do
      embedder = Engram::Embedder.new(fake_config) { |_, _| [1.0_f32, -2.5_f32, 3.0_f32] }

      bytes = embedder.embed("some memory text").not_nil!
      floats = Slice(Float32).new(bytes.to_unsafe.as(Float32*), bytes.size // 4)

      floats.to_a.should eq([1.0_f32, -2.5_f32, 3.0_f32])
      embedder.dimension.should eq(3)
      embedder.warned?.should be_false
    end

    it "passes the config and text through to the transport" do
      seen_model = nil
      seen_text = nil
      embedder = Engram::Embedder.new(fake_config(model: "specific-model")) do |cfg, text|
        seen_model = cfg.model
        seen_text = text
        [0.0_f32]
      end

      embedder.embed("hello world")

      seen_model.should eq("specific-model")
      seen_text.should eq("hello world")
    end

    it "warns once and returns nil forever after when the transport raises" do
      calls = 0
      embedder = Engram::Embedder.new(fake_config) do |_, _|
        calls += 1
        raise "boom"
      end

      embedder.embed("first").should be_nil
      embedder.warned?.should be_true

      embedder.embed("second").should be_nil
      calls.should eq(1)
    end
  end
end
