#ifndef STUDIO_LUAU_ANALYSIS_H
#define STUDIO_LUAU_ANALYSIS_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Immutable snapshots only: neither the runtime VM nor SceneModel enters this bridge.
typedef struct {
    const char *name;
    const char *source; // NULL for a non-source scene node
    int parent;
    int is_module;
} StudioAnalysisNode;
typedef void (*StudioAnalysisDiagnostic)(void *context, int node, unsigned start_line,
    unsigned start_column, unsigned end_line, unsigned end_column, const char *message);
void studio_luau_analyze(const StudioAnalysisNode *nodes, size_t count, int target,
    const char *definitions, const char *const *script_types,
    StudioAnalysisDiagnostic diagnostic, void *context);
#ifdef __cplusplus
}
#endif
#endif
