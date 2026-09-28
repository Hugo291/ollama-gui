import Foundation
import Testing
@testable import OllamaKit

@Suite("Model references")
struct ModelReferenceTests {
    @Test func parsesLibraryModel() throws {
        let reference = try #require(ModelReference("gemma3"))
        #expect(reference.host == "registry.ollama.ai")
        #expect(reference.namespace == "library")
        #expect(reference.repository == "gemma3")
        #expect(reference.tag == "latest")
        #expect(reference.shortName == "gemma3:latest")
        #expect(reference.manifestURL?.absoluteString == "https://registry.ollama.ai/v2/library/gemma3/manifests/latest")
        #expect(reference.webPageURL?.absoluteString == "https://ollama.com/library/gemma3")
    }

    @Test func parsesNamespacedAndHostedModels() throws {
        let user = try #require(ModelReference("qllama/bge-reranker-v2-m3:latest"))
        #expect(user.namespace == "qllama")
        #expect(user.shortName == "qllama/bge-reranker-v2-m3:latest")
        #expect(user.webPageURL?.absoluteString == "https://ollama.com/qllama/bge-reranker-v2-m3")

        let hf = try #require(ModelReference("hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M"))
        #expect(hf.host == "hf.co")
        #expect(hf.namespace == "unsloth")
        #expect(hf.tag == "Q4_K_M")
        #expect(!hf.isOfficialRegistry)
        #expect(hf.webPageURL?.absoluteString == "https://huggingface.co/unsloth/Qwen3-8B-GGUF")
    }

    @Test func detectsCloudTags() {
        #expect(ModelReference("kimi-k3:cloud")?.isCloudTag == true)
        #expect(ModelReference("gpt-oss:120b-cloud")?.isCloudTag == true)
        #expect(ModelReference("gemma3:4b")?.isCloudTag == false)
    }

    @Test func canonicalNamesMatchAcrossSpellings() {
        #expect(ModelReference.canonical("gemma3") == ModelReference.canonical("gemma3:latest"))
        #expect(ModelReference.canonical("registry.ollama.ai/library/gemma3:latest") == ModelReference.canonical("Gemma3"))
        #expect(ModelReference.canonical("gemma3:4b") != ModelReference.canonical("gemma3"))
    }

    @Test(arguments: ["", "  ", "bad name", "a//b", "model:", ":tag", "a/b/c/d", "mo$del"])
    func rejectsInvalidNames(_ name: String) {
        #expect(ModelReference(name) == nil)
    }
}

@Suite("Server addresses")
struct BaseURLTests {
    @Test(arguments: [
        ("localhost", "http://localhost:11434"),
        ("127.0.0.1:11434", "http://127.0.0.1:11434"),
        ("192.168.1.20", "http://192.168.1.20:11434"),
        ("http://192.168.1.20", "http://192.168.1.20:11434"),
        ("http://example.com:8080/", "http://example.com:8080"),
        ("https://ollama.example.com", "https://ollama.example.com"),
        ("https://example.com/ollama/", "https://example.com/ollama"),
        ("0.0.0.0:11434", "http://127.0.0.1:11434"),
        ("[::1]:11434", "http://[::1]:11434"),
    ])
    func normalizesAddresses(input: String, expected: String) {
        #expect(OllamaClient.baseURL(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "ftp://host", "http://", "not a host"])
    func rejectsInvalidAddresses(_ input: String) {
        #expect(OllamaClient.baseURL(from: input) == nil)
    }
}

@Suite("ollama.com parsing")
struct LibraryParserTests {
    static let searchHTML = """
    <ul role="list" class="grid grid-cols-1">
    <li class="flex items-baseline border-b border-neutral-200 py-6">
      <a href="/library/qwen3" class="group w-full">
        <div class="flex flex-col mb-1" title="qwen3">
          <h2 class="truncate text-xl font-medium"><span >qwen3</span></h2>
          <p class="max-w-lg break-words text-neutral-800 text-md">Qwen3 &amp; friends: dense and MoE models.</p>
        </div>
        <div class="flex flex-col">
          <div class="flex flex-wrap space-x-2">
            <span class="inline-flex my-1 items-center rounded-md bg-indigo-50 px-2">tools</span>
            <span class="inline-flex my-1 items-center rounded-md bg-indigo-50 px-2">thinking</span>
            <span class="inline-flex my-1 items-center rounded-md bg-[#ddf4ff] px-2">0.6b</span>
            <span class="inline-flex my-1 items-center rounded-md bg-[#ddf4ff] px-2">235b</span>
          </div>
          <p class="my-1 flex space-x-5 text-[13px] font-medium text-neutral-500">
            <span class="flex items-center"><svg></svg><span >21.4M</span><span class="hidden sm:flex">&nbsp;Pulls</span></span>
            <span class="flex items-center"><svg></svg><span >58</span><span class="hidden sm:flex">&nbsp;Tags</span></span>
            <span class="flex items-center" title="Jul 1, 2026"><svg></svg><span class="hidden sm:flex">Updated&nbsp;</span><span >2 months ago</span></span>
          </p>
        </div>
      </a>
    </li>
    <li class="flex"><a href="/qllama/bge-reranker-v2-m3" class="group w-full"><h2><span>qllama/bge-reranker-v2-m3</span></h2>
      <p class="max-w-lg">Reranker</p><span class="inline-flex px-2">e4b</span><span class="inline-flex px-2">8x7b</span></a></li>
    <li><a href="/blog">Blog</a></li>
    </ul>
    """

    static let tagsHTML = """
    <div class="group px-4 py-3">
      <a href="/library/qwen3.8:latest" class="md:hidden flex flex-col space-y-[6px] group">
        <div><span class="group-hover:underline">qwen3.8:latest</span></div>
        <div class="flex flex-col text-neutral-500 text-[13px]">
          <span><span class="font-mono">
            e118e4d12a70</span> • 18GB • 256K context window  •
            <span class="hidden sm:inline">
              Text, Image input •
              2 days ago
            </span>
          </span>
          <div class="flex sm:hidden">Text, Image input • 2 days ago</div>
        </div>
      </a>
      <div class="hidden md:flex"><a href="/library/qwen3.8:latest" class="group-hover:underline">qwen3.8:latest</a></div>
    </div>
    <a href="/library/qwen3.8:27b-mlx" class="md:hidden flex flex-col">
      <span>qwen3.8:27b-mlx</span> <span>MLX</span>
      <span class="font-mono">5642e97495e1</span> • 18GB • 256K context window • Text, Image input • 1 month ago
    </a>
    <a href="/library/kimi-k3:cloud" class="md:hidden flex flex-col">
      <span>kimi-k3:cloud</span> <span class="font-mono">a399e41d21c0</span> • Extra High Usage • 1M context window • Text, Image input • 2 months ago
    </a>
    """

    @Test func parsesSearchResults() throws {
        let results = LibraryParser.parseSearch(Self.searchHTML)
        #expect(results.count == 2)

        let qwen = try #require(results.first)
        #expect(qwen.path == "library/qwen3")
        #expect(qwen.name == "qwen3")
        #expect(qwen.pullName == "qwen3")
        #expect(qwen.summary == "Qwen3 & friends: dense and MoE models.")
        #expect(qwen.capabilities == ["tools", "thinking"])
        #expect(qwen.sizes == ["0.6b", "235b"])
        #expect(qwen.pulls == "21.4M")
        #expect(qwen.tagCount == "58")
        #expect(qwen.updated == "2 months ago")
        #expect(qwen.pageURL.absoluteString == "https://ollama.com/library/qwen3")

        let community = results[1]
        #expect(community.pullName == "qllama/bge-reranker-v2-m3")
        #expect(community.sizes == ["e4b", "8x7b"])
        #expect(community.capabilities.isEmpty)
    }

    @Test func parsesTags() throws {
        let tags = LibraryParser.parseTags(Self.tagsHTML)
        #expect(tags.map(\.name) == ["qwen3.8:latest", "qwen3.8:27b-mlx", "kimi-k3:cloud"])

        let latest = tags[0]
        #expect(latest.digest == "e118e4d12a70")
        #expect(latest.size == "18GB")
        #expect(latest.context == "256K context window")
        #expect(latest.input == "Text, Image input")
        #expect(latest.updated == "2 days ago")
        #expect(latest.badges.isEmpty)

        #expect(tags[1].badges == ["MLX"])
        #expect(tags[1].tag == "27b-mlx")

        let cloud = tags[2]
        #expect(cloud.isCloud)
        #expect(cloud.size == "Extra High Usage")
        #expect(cloud.updated == "2 months ago")
    }

    @Test func toleratesUnknownMarkup() {
        #expect(LibraryParser.parseSearch("<html><body>nothing</body></html>").isEmpty)
        #expect(LibraryParser.parseTags("").isEmpty)
    }

    @Test func decodesEntities() {
        #expect(LibraryParser.decodeEntities("a &amp; b &#39;c&#x27; &lt;d&gt; &unknown;") == "a & b 'c' <d> &unknown;")
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func formatsTokens() {
        #expect(Format.tokens(8192) == "8K")
        #expect(Format.tokens(262_144) == "256K")
        #expect(Format.tokens(1_048_576) == "1M")
        #expect(Format.tokens(512) == "512")
    }

    @Test func formatsParameterCounts() {
        #expect(Format.parameterCount(268_098_176) == "268M")
        #expect(Format.parameterCount(4_300_000_000) == "4.3B")
        #expect(Format.parameterCount(2_812_000_000_000) == "2.8T")
        #expect(Format.parameterCount(8_000_000_000) == "8B")
    }

    @Test func parsesParameterLabels() {
        #expect(Format.parameterValue("873.44M") == 873_440_000)
        #expect(Format.parameterValue("4.4B") == 4_400_000_000)
        #expect(Format.parameterValue("2.81T") > Format.parameterValue("753B"))
        #expect(Format.parameterValue(nil) == 0)
    }
}
