// Il SQLite di sistema di Ubuntu è compilato senza SQLITE_ENABLE_SNAPSHOT, mentre GRDB (su sistema) lo presuppone.
// Queste funzioni NON vengono mai chiamate dall'app (servono solo a funzionalità di GRDB che non usiamo:
// DatabasePool snapshot). Il file è attivo solo su Linux: su macOS si usa il SQLite di sistema, che le contiene già.
#include "csqlite_linux_shim.h"

#if defined(__linux__)
#include <sqlite3.h>
#include <stddef.h>

int sqlite3_snapshot_get(sqlite3 *db, const char *schema, sqlite3_snapshot **out) { (void)db; (void)schema; if (out) *out = NULL; return SQLITE_ERROR; }
int sqlite3_snapshot_open(sqlite3 *db, const char *schema, sqlite3_snapshot *snap) { (void)db; (void)schema; (void)snap; return SQLITE_ERROR; }
void sqlite3_snapshot_free(sqlite3_snapshot *snap) { (void)snap; }
int sqlite3_snapshot_cmp(sqlite3_snapshot *a, sqlite3_snapshot *b) { (void)a; (void)b; return 0; }
#endif

int teostack_linux_shim_present(void) { return 1; }
