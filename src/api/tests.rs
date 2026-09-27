use serde_json::json;

use super::client::parse_address;
use super::format::{self, Lang};
use super::library::{decode_entities, parse_search, parse_tags};
use super::models::{ChatChunk, ModelInfo, OllamaModel, RunningModel, capability, parse_date};
use super::reference::{ModelReference, canonical};

#[test]
fn decodes_tags_with_local_cloud_and_legacy_models() {
    let json = json!({"models": [
        {"name": "kimi-k3:cloud", "remote_model": "kimi-k3", "remote_host": "https://ollama.com",
         "modified_at": "2026-09-07T23:25:52.874993187+02:00", "size": 308, "digest": "630e7374",
         "details": {"format": "", "family": "", "families": null, "parameter_size": "2.81T", "quantization_level": "MXFP4", "context_length": 1048576},
         "capabilities": ["vision", "thinking", "completion", "tools"]},
        {"name": "gemma3:270m", "modified_at": "2026-09-07T02:50:45Z", "size": 291554930,
         "digest": "sha256:e7d36fb2c3b3293cfe56d55889867a064b3a2b22e98335f2e6e8a387e081d6be",
         "details": {"format": "gguf", "family": "gemma3", "families": ["gemma3"], "parameter_size": "268.10M", "quantization_level": "Q8_0"},
         "capabilities": ["completion"]},
        {"name": "bge-m3:latest", "size": 1157672605, "digest": "79076464", "capabilities": ["embedding"]},
        {"name": "x/z-image-turbo:latest", "size": 12773500825u64, "digest": "77b78ce4", "capabilities": ["image"]},
        {"name": "legacy:latest", "size": 10, "digest": "00"},
        {"size": 1}
    ]});
    let models: Vec<OllamaModel> = json["models"].as_array().unwrap().iter().filter_map(OllamaModel::from_json).collect();
    assert_eq!(models.len(), 5, "a model without a name is skipped");

    let cloud = &models[0];
    assert!(cloud.is_cloud());
    assert!(!cloud.can_load());
    assert!(cloud.can_chat());
    assert_eq!(cloud.parameter_size().as_deref(), Some("2.81T"));
    assert_eq!(cloud.format(), None);
    assert_eq!(cloud.details.context_length, Some(1_048_576));
    assert!(cloud.modified_at.is_some());

    let gemma = &models[1];
    assert!(!gemma.is_cloud());
    assert!(gemma.can_load());
    assert_eq!(gemma.family().as_deref(), Some("gemma3"));
    assert_eq!(gemma.short_digest(), "e7d36fb2c3b3");

    assert!(!models[2].can_chat());
    assert!(models[2].supports(capability::EMBEDDING));
    assert!(!models[3].can_load());
    assert!(models[4].can_chat(), "models without capabilities are text models");
}

#[test]
fn running_models_and_processor_labels() {
    let gpu = RunningModel::from_json(
        &json!({"name": "a", "size": 9609987250u64, "size_vram": 9609987250u64, "context_length": 8192, "expires_at": "2026-09-27T22:57:10.939373+02:00"}),
    )
    .unwrap();
    let cpu = RunningModel::from_json(&json!({"name": "b", "size": 3000, "size_vram": 0, "expires_at": "2318-01-01T00:00:00Z"})).unwrap();
    let split = RunningModel::from_json(&json!({"name": "c", "size": 1000, "size_vram": 480})).unwrap();
    assert_eq!(gpu.processor_label(), "100% GPU");
    assert_eq!(gpu.context_length, Some(8192));
    assert!(gpu.expires_at.is_some());
    assert_eq!(cpu.processor_label(), "100% CPU");
    assert!(cpu.stays_loaded());
    assert_eq!(split.processor_label(), "52%/48% CPU/GPU");
    assert!((split.gpu_share() - 0.48).abs() < 1e-4);
}

#[test]
fn show_response_keeps_dotted_model_info_keys() {
    let info = ModelInfo::from_json(&json!({
        "license": "\n Gemma Terms of Use\n\nMore text",
        "parameters": "stop                           \"<end_of_turn>\"\ntop_k                          64\ntemperature 0.2",
        "system": "You are a pirate.",
        "details": {"family": "gemma3", "parameter_size": "268.10M"},
        "model_info": {"general.architecture": "gemma3", "general.parameter_count": 268098176, "gemma3.context_length": 32768,
                       "gemma3.embedding_length": 640, "tokenizer.ggml.tokens": null},
        "tensors": [{"name": "output_norm.weight", "type": "F32", "shape": [640]}],
        "requires": "0.14.0"
    }));
    assert_eq!(info.architecture().as_deref(), Some("gemma3"));
    assert_eq!(info.context_length(), Some(32768));
    assert_eq!(info.embedding_length(), Some(640));
    assert_eq!(info.parameter_count(), Some(268_098_176));
    assert_eq!(info.license_title().as_deref(), Some("Gemma Terms of Use"));
    assert_eq!(info.tensors[0].shape, vec![640]);
    let parameters = info.parameter_list();
    assert_eq!(parameters.iter().map(|p| p.key.as_str()).collect::<Vec<_>>(), ["stop", "top_k", "temperature"]);
    assert_eq!(parameters[0].value, "<end_of_turn>");
}

#[test]
fn chat_chunks() {
    let partial = ChatChunk::from_json(&json!({"message": {"role": "assistant", "content": "Hel", "thinking": "hmm"}, "done": false}));
    assert_eq!(partial.content, "Hel");
    assert_eq!(partial.thinking, "hmm");
    assert!(!partial.done);
    let last = ChatChunk::from_json(&json!({"message": {"content": ""}, "done": true, "eval_count": 100, "eval_duration": 2_000_000_000u64}));
    assert_eq!(last.tokens_per_second(), Some(50.0));
}

#[test]
fn dates_with_nanoseconds() {
    let date = parse_date(Some(&json!("2026-09-07T23:25:52.874993187+02:00"))).unwrap();
    assert_eq!(date.timestamp(), 1_788_816_352);
    assert_eq!(date.timestamp_subsec_micros(), 874_993);
    assert!(parse_date(Some(&json!("yesterday"))).is_none());
    assert!(parse_date(None).is_none());
}

#[test]
fn model_references() {
    let reference = ModelReference::parse("gemma3").unwrap();
    assert_eq!(reference.namespace, "library");
    assert_eq!(reference.tag, "latest");
    assert_eq!(reference.short_name(), "gemma3:latest");
    assert_eq!(reference.manifest_url(), "https://registry.ollama.ai/v2/library/gemma3/manifests/latest");
    assert_eq!(reference.web_page().as_deref(), Some("https://ollama.com/library/gemma3"));

    assert_eq!(ModelReference::parse("qllama/bge-reranker-v2-m3:latest").unwrap().short_name(), "qllama/bge-reranker-v2-m3:latest");
    let hf = ModelReference::parse("hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M").unwrap();
    assert_eq!(hf.host, "hf.co");
    assert!(!hf.is_official_registry());
    assert_eq!(hf.web_page().as_deref(), Some("https://huggingface.co/unsloth/Qwen3-8B-GGUF"));

    assert!(ModelReference::parse("kimi-k3:cloud").unwrap().is_cloud_tag());
    assert!(ModelReference::parse("gpt-oss:120b-cloud").unwrap().is_cloud_tag());
    assert_eq!(canonical("gemma3"), canonical("registry.ollama.ai/library/gemma3:latest"));
    assert_ne!(canonical("gemma3:4b"), canonical("gemma3"));
    for bad in ["", "  ", "bad name", "a//b", "model:", ":tag", "a/b/c/d", "mo$del"] {
        assert!(ModelReference::parse(bad).is_none(), "{bad:?}");
    }
}

#[test]
fn server_addresses() {
    let cases = [
        ("localhost", "http://localhost:11434"),
        ("192.168.1.20", "http://192.168.1.20:11434"),
        ("http://192.168.1.20", "http://192.168.1.20:11434"),
        ("http://example.com:8080/", "http://example.com:8080"),
        ("https://ollama.example.com", "https://ollama.example.com"),
        ("https://example.com/ollama/", "https://example.com/ollama"),
        ("0.0.0.0:11434", "http://127.0.0.1:11434"),
    ];
    for (input, expected) in cases {
        let url = parse_address(input).unwrap_or_else(|| panic!("{input}"));
        assert_eq!(super::client::display_url(&url), expected, "{input}");
    }
    for bad in ["", "ftp://host", "http://", "not a host"] {
        assert!(parse_address(bad).is_none(), "{bad:?}");
    }
}

const SEARCH_HTML: &str = r#"
<li class="flex items-baseline border-b border-neutral-200 py-6">
  <a href="/library/qwen3" class="group w-full">
    <div class="flex flex-col mb-1" title="qwen3">
      <h2 class="truncate text-xl font-medium"><span >qwen3</span></h2>
      <p class="max-w-lg break-words text-neutral-800 text-md">Qwen3 &amp; friends: dense and MoE models.</p>
    </div>
    <div class="flex flex-wrap space-x-2">
      <span class="inline-flex my-1 items-center rounded-md bg-indigo-50 px-2">tools</span>
      <span class="inline-flex my-1 items-center rounded-md bg-indigo-50 px-2">thinking</span>
      <span class="inline-flex my-1 items-center rounded-md bg-[#ddf4ff] px-2">0.6b</span>
    </div>
    <p class="my-1 flex">
      <span class="flex items-center"><svg></svg><span >21.4M</span><span class="hidden sm:flex">&nbsp;Pulls</span></span>
      <span class="flex items-center"><svg></svg><span >58</span><span class="hidden sm:flex">&nbsp;Tags</span></span>
      <span class="flex items-center"><svg></svg><span class="hidden sm:flex">Updated&nbsp;</span><span >2 months ago</span></span>
    </p>
  </a>
</li>
<li><a href="/qllama/bge-reranker-v2-m3" class="group w-full"><h2><span>qllama/bge-reranker-v2-m3</span></h2>
  <p class="max-w-lg">Reranker</p><span class="inline-flex px-2">e4b</span><span class="inline-flex px-2">8x7b</span></a></li>
<li><a href="/blog">Blog</a></li>"#;

const TAGS_HTML: &str = r#"
<a href="/library/qwen3.8:latest" class="md:hidden flex flex-col space-y-[6px] group">
  <div><span class="group-hover:underline">qwen3.8:latest</span></div>
  <span><span class="font-mono">
    e118e4d12a70</span> • 18GB • 256K context window  •
    <span class="hidden sm:inline">Text, Image input • 2 days ago</span></span>
  <div class="flex sm:hidden">Text, Image input • 2 days ago</div>
</a>
<a href="/library/qwen3.8:27b-mlx" class="md:hidden flex flex-col">
  <span>qwen3.8:27b-mlx</span> <span>MLX</span>
  <span class="font-mono">5642e97495e1</span> • 18GB • 256K context window • Text, Image input • 1 month ago
</a>
<a href="/library/kimi-k3:cloud" class="md:hidden flex flex-col">
  <span>kimi-k3:cloud</span> <span class="font-mono">a399e41d21c0</span> • Extra High Usage • 1M context window • Text, Image input • 2 months ago
</a>"#;

#[test]
fn parses_search_results() {
    let results = parse_search(SEARCH_HTML);
    assert_eq!(results.len(), 2);
    let qwen = &results[0];
    assert_eq!(qwen.path, "library/qwen3");
    assert_eq!(qwen.pull_name(), "qwen3");
    assert_eq!(qwen.summary, "Qwen3 & friends: dense and MoE models.");
    assert_eq!(qwen.capabilities, ["tools", "thinking"]);
    assert_eq!(qwen.sizes, ["0.6b"]);
    assert_eq!(qwen.pulls.as_deref(), Some("21.4M"));
    assert_eq!(qwen.tag_count.as_deref(), Some("58"));
    assert_eq!(qwen.updated.as_deref(), Some("2 months ago"));
    assert_eq!(results[1].pull_name(), "qllama/bge-reranker-v2-m3");
    assert_eq!(results[1].sizes, ["e4b", "8x7b"]);
}

#[test]
fn parses_tags() {
    let tags = parse_tags(TAGS_HTML);
    assert_eq!(tags.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["qwen3.8:latest", "qwen3.8:27b-mlx", "kimi-k3:cloud"]);
    assert_eq!(tags[0].digest.as_deref(), Some("e118e4d12a70"));
    assert_eq!(tags[0].size.as_deref(), Some("18GB"));
    assert_eq!(tags[0].context.as_deref(), Some("256K context window"));
    assert_eq!(tags[0].input.as_deref(), Some("Text, Image input"));
    assert_eq!(tags[0].updated.as_deref(), Some("2 days ago"));
    assert_eq!(tags[1].badges, ["MLX"]);
    assert_eq!(tags[1].tag(), "27b-mlx");
    assert_eq!(tags[2].size.as_deref(), Some("Extra High Usage"));
}

#[test]
fn entities_and_unknown_markup() {
    assert_eq!(decode_entities("a &amp; b &#39;c&#x27; &lt;d&gt; &unknown;"), "a & b 'c' <d> &unknown;");
    assert!(parse_search("<html></html>").is_empty());
    assert!(parse_tags("").is_empty());
}

#[test]
fn formatting() {
    assert_eq!(format::tokens(8192), "8K");
    assert_eq!(format::tokens(262_144), "256K");
    assert_eq!(format::tokens(1_048_576), "1M");
    assert_eq!(format::parameter_count(268_098_176), "268M");
    assert_eq!(format::parameter_count(4_300_000_000), "4.3B");
    assert_eq!(format::parameter_count(8_000_000_000), "8B");
    assert!(format::parameter_value(Some("2.81T")) > format::parameter_value(Some("753B")));
    assert_eq!(format::bytes(291_554_930, Lang::En), "291.6 MB");
    assert_eq!(format::bytes(12_773_500_825, Lang::En), "12.77 GB");
    assert_eq!(format::bytes(1_157_672_605, Lang::Fr), "1,16 Go");
    assert_eq!(format::duration(std::time::Duration::from_secs(3900)), "1 h 05 min");
    assert_eq!(format::relative_time(chrono::TimeDelta::days(21), Lang::En), "3 wk ago");
    assert_eq!(format::relative_time(chrono::TimeDelta::days(21), Lang::Fr), "il y a 3 sem.");
}
