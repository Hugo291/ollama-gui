import Foundation
import Testing
@testable import OllamaKit

@Suite("Decoding")
struct DecodingTests {
    @Test func decodesTagsWithLocalAndCloudModels() throws {
        let json = """
        {"models":[
          {"name":"kimi-k3:cloud","model":"kimi-k3:cloud","remote_model":"kimi-k3","remote_host":"https://ollama.com",
           "modified_at":"2026-09-07T23:25:52.874993187+02:00","size":308,"digest":"630e737485bd",
           "details":{"parent_model":"","format":"","family":"","families":null,"parameter_size":"2.81T","quantization_level":"MXFP4","context_length":1048576},
           "capabilities":["vision","thinking","completion","tools"]},
          {"name":"gemma3:270m","model":"gemma3:270m","modified_at":"2026-09-07T02:50:45Z","size":291554930,
           "digest":"sha256:e7d36fb2c3b3293cfe56d55889867a064b3a2b22e98335f2e6e8a387e081d6be",
           "details":{"format":"gguf","family":"gemma3","families":["gemma3"],"parameter_size":"268.10M","quantization_level":"Q8_0"},
           "capabilities":["completion"]},
          {"name":"bge-m3:latest","size":1157672605,"digest":"79076464","capabilities":["embedding"]},
          {"name":"x/z-image-turbo:latest","size":12773500825,"digest":"77b78ce4","capabilities":["image"]},
          {"name":"legacy:latest","size":10,"digest":"00"}
        ]}
        """
        let models = try JSONDecoder().decode(TagsResponse.self, from: Data(json.utf8)).models
        #expect(models.count == 5)

        let cloud = models[0]
        #expect(cloud.isCloud)
        #expect(!cloud.canLoad)
        #expect(cloud.canChat)
        #expect(cloud.parameterSize == "2.81T")
        #expect(cloud.format == nil)
        #expect(cloud.details?.contextLength == 1_048_576)
        #expect(cloud.modifiedAt != nil)

        let gemma = models[1]
        #expect(!gemma.isCloud)
        #expect(gemma.canLoad)
        #expect(gemma.family == "gemma3")
        #expect(gemma.shortDigest == "e7d36fb2c3b3")

        #expect(!models[2].canChat)
        #expect(models[2].supports(.embedding))
        #expect(!models[3].canLoad)
        #expect(models[4].canChat, "Models without capabilities are assumed to be text models")
    }

    @Test func decodesRunningModels() throws {
        let json = """
        {"models":[
          {"name":"gemma4:e4b-mlx","model":"gemma4:e4b-mlx","size":9609987250,"digest":"64af","details":{"format":"safetensors","quantization_level":"nvfp4"},
           "expires_at":"2026-09-27T22:57:10.939373+02:00","size_vram":9609987250,"context_length":8192},
          {"name":"qwen3.5:2b","size":3000,"size_vram":0,"expires_at":"2318-01-01T00:00:00Z"},
          {"name":"split:latest","size":1000,"size_vram":480}
        ]}
        """
        let running = try JSONDecoder().decode(RunningResponse.self, from: Data(json.utf8)).models
        #expect(running.count == 3)
        #expect(running[0].processorLabel == "100% GPU")
        #expect(running[0].contextLength == 8192)
        #expect(running[0].expiresAt != nil)
        #expect(running[1].processorLabel == "100% CPU")
        #expect(running[1].staysLoaded)
        #expect(running[2].processorLabel == "52%/48% CPU/GPU")
        #expect(abs(running[2].gpuShare - 0.48) < 0.0001)
    }

    @Test func showResponseKeepsDottedModelInfoKeys() throws {
        let json = """
        {"license":"\\n Gemma Terms of Use\\n\\nMore text",
         "parameters":"stop                           \\"<end_of_turn>\\"\\ntop_k                          64\\ntemperature 0.2",
         "system":"You are a pirate.",
         "details":{"family":"gemma3","parameter_size":"268.10M"},
         "model_info":{"general.architecture":"gemma3","general.parameter_count":268098176,"gemma3.context_length":32768,
                       "gemma3.embedding_length":640,"gemma3.attention.layer_norm_rms_epsilon":1e-06,"tokenizer.ggml.tokens":null},
         "capabilities":["completion"],"modified_at":"2026-09-07T02:50:45.344165439+02:00","requires":"0.14.0"}
        """
        let info = try JSONDecoder().decode(ModelShowResponse.self, from: Data(json.utf8))
        #expect(info.architecture == "gemma3")
        #expect(info.contextLength == 32768)
        #expect(info.embeddingLength == 640)
        #expect(info.parameterCount == 268_098_176)
        #expect(info.modelInfo?["gemma3.attention.layer_norm_rms_epsilon"]?.displayString == "1e-06")
        #expect(info.modelInfo?["tokenizer.ggml.tokens"] == .null)
        #expect(info.licenseTitle == "Gemma Terms of Use")
        #expect(info.system == "You are a pirate.")
        #expect(info.requires == "0.14.0")

        let parameters = info.parameterList
        #expect(parameters.map(\.key) == ["stop", "top_k", "temperature"])
        #expect(parameters[0].value == "<end_of_turn>")
        #expect(parameters[1].value == "64")
    }

    @Test func decodesChatChunks() throws {
        let partial = try JSONDecoder().decode(ChatChunk.self, from: Data(#"{"model":"m","message":{"role":"assistant","content":"Hel","thinking":"hmm"},"done":false}"#.utf8))
        #expect(partial.message?.content == "Hel")
        #expect(partial.message?.thinking == "hmm")
        #expect(!partial.done)

        let final = try JSONDecoder().decode(ChatChunk.self, from: Data(#"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","eval_count":100,"eval_duration":2000000000,"prompt_eval_count":12}"#.utf8))
        #expect(final.done)
        #expect(final.tokensPerSecond == 50)
        #expect(final.promptEvalCount == 12)
    }

    @Test func encodesRequestsWithOllamaKeys() throws {
        let chat = ChatRequest(model: "m", messages: [ChatMessage(role: "user", content: "hi")], think: true, options: ["temperature": 0.5, "num_ctx": 4096], keepAlive: 300)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any]
        #expect(object?["keep_alive"] as? Int == 300)
        #expect(object?["think"] as? Bool == true)
        let options = object?["options"] as? [String: Any]
        #expect(options?["num_ctx"] as? Int == 4096)
        #expect(options?["temperature"] as? Double == 0.5)
        let message = (object?["messages"] as? [[String: Any]])?.first
        #expect(message?["thinking"] == nil)
    }

    @Test(arguments: [
        ("2026-09-07T23:25:52.874993187+02:00", 1_788_816_352.874993),
        ("2026-09-27T21:02:38.473044Z", 1_790_542_958.473044),
        ("2026-09-07T02:50:45Z", 1_788_749_445.0),
    ])
    func parsesOllamaDates(input: String, expected: Double) throws {
        let date = try #require(OllamaDate.parse(input))
        #expect(abs(date.timeIntervalSince1970 - expected) < 0.001)
    }

    @Test func rejectsInvalidDates() {
        #expect(OllamaDate.parse("") == nil)
        #expect(OllamaDate.parse("yesterday") == nil)
    }
}
