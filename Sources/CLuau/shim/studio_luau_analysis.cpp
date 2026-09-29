#include "studio_luau_analysis.h"
#include "Luau/Ast.h"
#include "Luau/BuiltinDefinitions.h"
#include "Luau/Frontend.h"
#include "Luau/Type.h"
#include "Luau/TypeInfer.h"
#include "Luau/ToString.h"
#include <cstdlib>
#include <exception>
#include <string>
#include <mutex>

namespace {
struct SnapshotResolver final : Luau::FileResolver {
    const StudioAnalysisNode *nodes;
    size_t count;
    SnapshotResolver(const StudioAnalysisNode *nodes, size_t count): nodes(nodes), count(count) {}
    int index(const std::string& name) const {
        if (name.size() < 2 || name[0] != '@') return -1;
        char *end = nullptr;
        long result = std::strtol(name.c_str() + 1, &end, 10);
        return *end == 0 && result >= 0 && size_t(result) < count ? int(result) : -1;
    }
    std::string key(int i) const { return "@" + std::to_string(i); }
    std::optional<Luau::SourceCode> readSource(const Luau::ModuleName& name) override {
        int i = index(name);
        if (i < 0 || !nodes[i].source) return std::nullopt;
        return Luau::SourceCode{nodes[i].source, nodes[i].is_module ? Luau::SourceCode::Module : Luau::SourceCode::Script};
    }
    int child(int parent, const std::string& name) const {
        for (size_t i = 0; i < count; ++i)
            if (nodes[i].parent == parent && name == nodes[i].name) return int(i);
        return -1;
    }
    std::optional<Luau::ModuleInfo> resolveModule(const Luau::ModuleInfo *context, Luau::AstExpr *expr) override {
        int result = -1;
        int base = context ? index(context->name) : -1;
        if (auto global = expr->as<Luau::AstExprGlobal>()) {
            std::string name = global->name.value;
            if (name == "script") result = base;
            else if (name == "game") return Luau::ModuleInfo{"game"};
            else if (name == "workspace" || name == "Workspace") result = child(-1, "Workspace");
        } else if (auto access = expr->as<Luau::AstExprIndexName>()) {
            std::string name = access->index.value;
            if (base >= 0) result = name == "Parent" ? nodes[base].parent : child(base, name);
            else if (context && context->name == "game") result = child(-1, name);
        } else if (auto access = expr->as<Luau::AstExprIndexExpr>()) {
            if (auto name = access->index->as<Luau::AstExprConstantString>())
                result = child(base, std::string(name->value.data, name->value.size));
        } else if (auto call = expr->as<Luau::AstExprCall>(); call && call->self && call->args.size) {
            auto method = call->func->as<Luau::AstExprIndexName>();
            auto name = call->args.data[0]->as<Luau::AstExprConstantString>();
            if (method && name) {
                std::string member = method->index.value;
                std::string value(name->value.data, name->value.size);
                if (member == "GetService" && context && context->name == "game") result = child(-1, value);
                else if (member == "WaitForChild" || member == "FindFirstChild") result = child(base, value);
            }
        }
        if (result >= 0) return Luau::ModuleInfo{key(result)};
        return std::nullopt;
    }
    std::string getHumanReadableModuleName(const Luau::ModuleName& name) const override {
        int i = index(name);
        return i >= 0 ? nodes[i].name : name;
    }
};
// Some Luau built-in internals use process-wide structures; serialize analyzer calls,
// independently of (and without locking) the runtime VM.
std::mutex analysisMutex;
}

extern "C" void studio_luau_analyze(const StudioAnalysisNode *nodes, size_t count, int target,
    const char *definitions, const char *const *script_types,
    StudioAnalysisDiagnostic diagnostic, void *context) {
    std::lock_guard<std::mutex> lock(analysisMutex);
    if (!diagnostic || target < 0 || size_t(target) >= count) return;
    auto issue = [&](const std::string& message) { diagnostic(context, target, 0, 0, 0, 1, message.c_str()); };
    try {
        SnapshotResolver resolver(nodes, count);
        Luau::NullConfigResolver config;
        Luau::FrontendOptions options;
        options.moduleTimeLimitSec = 0.2;
        options.retainFullTypeGraphs = false;
        Luau::Frontend frontend(&resolver, &config, options);
        Luau::registerBuiltinGlobals(frontend, frontend.globals);
        auto result = frontend.loadDefinitionFile(frontend.globals, frontend.globals.globalScope,
            definitions, "Studio", false);
        if (!result.success) {
            std::string message = "Studio type definitions could not be loaded";
            if (!result.parseResult.errors.empty()) message += ": " + std::string(result.parseResult.errors.front().what());
            else if (result.module && !result.module->errors.empty()) message += ": " + Luau::toString(result.module->errors.front());
            issue(message);
            return;
        }
        frontend.prepareModuleScope = [&](const Luau::ModuleName& name, const Luau::ScopePtr& scope, bool) {
            int i = resolver.index(name);
            if (i < 0 || !script_types || !script_types[i]) return;
            auto type = frontend.globals.globalScope->lookupType(script_types[i]);
            if (type) scope->bindings[frontend.globals.globalNames.names->getOrAdd("script")] = Luau::Binding{type->type};
        };
        auto checked = frontend.check(resolver.key(target));
        unsigned emitted = 0;
        for (const auto& error : checked.errors) {
            if (++emitted > 100) break;
            const auto& loc = error.location;
            std::string message = Luau::toString(error, Luau::TypeErrorToStringOptions{&resolver});
            diagnostic(context, resolver.index(error.moduleName), loc.begin.line, loc.begin.column,
                loc.end.line, loc.end.column, message.c_str());
        }
        if (!checked.timeoutHits.empty()) issue("Type analysis exceeded its complexity budget; simplify this script or its required modules.");
    } catch (const std::exception& error) {
        issue(std::string("Type analysis stopped: ") + error.what());
    } catch (...) {
        issue("Type analysis stopped because the script is too complex.");
    }
}
