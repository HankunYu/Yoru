import Foundation
import Testing
@testable import Yoru

struct ShaderCheckTests {
    private func check(_ source: String) throws -> ShaderCheck.Result {
        let file = FileManager.default.temporaryDirectory.appending(path: "check-\(UUID().uuidString).glsl")
        try source.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        return ShaderCheck.run(shader: file.path)
    }

    @Test func aSoundShaderRaisesNothing() throws {
        let result = try check("""
        //!HOOK MAIN
        //!BIND HOOKED
        vec4 hook() { return vec4(1.0 - HOOKED_tex(HOOKED_pos).rgb, 1.0); }
        """)
        print("CHECK good:", result)
        #expect(result.didRun)
        #expect(result.messages.isEmpty)
    }

    @Test func theBuiltInShadersRaiseNothing() throws {
        #expect(ShaderLibrary.builtInShaders.count == 3)
        for shader in ShaderLibrary.builtInShaders {
            let result = ShaderCheck.run(shader: ShaderLibrary.path(of: shader))
            #expect(result.isClean, "\(shader): \(result.messages)")
        }
    }

    @Test func aBrokenShaderIsReported() throws {
        let result = try check("""
        //!HOOK MAIN
        //!BIND HOOKED
        vec4 hook() { return vec4(1.0 - HOOKED_tex(HOOKED_pos).rgb, 1.0) + undefinedThing; }
        """)
        print("CHECK bad:", result)
        #expect(!result.messages.isEmpty)
    }
}

struct ShaderCheckOutputTests {
    @Test func keepsTheComplaintAndDropsTheDump() {
        let lines = [
            "shaderc output:", "input:75: error: 'undefinedThing' : undeclared identifier",
            "shaderc compile status 'error' (1 errors, 0 warnings)",
            "vk_compile_glsl(gpu, tmp, ...): VK_ERROR_INITIALIZATION_FAILED (gpu_pass.c:461)",
            "vertex shader source:", "[  1] #version 450", "[ 12]     layout(offset=0) vec2 _4;",
            "Backtrace:", "#0  1   Yoru.debug.dylib   0x0000000105e4f230 pl_pass_create + 1512",
            "Failed executing hook, disabling", "",
        ]
        #expect(lines.filter(ShaderCheck.isWorthShowing) == [
            "input:75: error: 'undefinedThing' : undeclared identifier",
            "shaderc compile status 'error' (1 errors, 0 warnings)",
            "Failed executing hook, disabling",
        ])
    }
}
