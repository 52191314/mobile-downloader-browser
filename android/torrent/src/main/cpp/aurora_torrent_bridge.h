#pragma once
// aurora_torrent_bridge.h — BSD-3-Clause clean BitTorrent bridge.
// Original code written for Aurora Download Manager (2026). Provides the
// lt_* C ABI consumed by lib/torrent/aurora_torrent_engine.dart.
//
// Links against rasterbar libtorrent (BSD-3-Clause). Nothing here is derived
// from the GPL-3.0 libtorrent_flutter plugin.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void*   lt_session_t;
typedef int64_t lt_torrent_id;

/* torrent states (mirrors AuroraTorrentState mapping in Dart) */
#define LT_STATE_QUEUED             0
#define LT_STATE_CHECKING_FILES     1
#define LT_STATE_DOWNLOADING_META   2
#define LT_STATE_DOWNLOADING        3
#define LT_STATE_FINISHED           4
#define LT_STATE_SEEDING            5
#define LT_STATE_ALLOCATING         6
#define LT_STATE_CHECKING_RESUME    7
#define LT_STATE_PAUSED             8
#define LT_STATE_ERROR              9
#define LT_STATE_UNKNOWN           -1

typedef struct {
    lt_torrent_id id;
    char          name[512];
    char          save_path[1024];
    char          error_msg[256];
    int32_t       state;
    float         progress;
    int32_t       download_rate;
    int32_t       upload_rate;
    int64_t       total_done;
    int64_t       total_wanted;
    int64_t       total_uploaded;
    int32_t       num_peers;
    int32_t       num_seeds;
    int32_t       num_pieces;
    int32_t       pieces_done;
    int32_t       is_paused;
    int32_t       is_finished;
    int32_t       has_metadata;
    int32_t       queue_position;
} lt_torrent_status;

/* session */
lt_session_t lt_create_session(const char* save_path, int listen_port, int alert_mask);
void         lt_destroy_session(lt_session_t session);

/* torrent management */
lt_torrent_id lt_add_magnet        (lt_session_t session, const char* magnet_uri, const char* save_path, int flags);
lt_torrent_id lt_add_torrent_file  (lt_session_t session, const char* file_path,  const char* save_path, int flags);
void          lt_pause_torrent     (lt_session_t session, lt_torrent_id id);
void          lt_resume_torrent    (lt_session_t session, lt_torrent_id id);
void          lt_remove_torrent    (lt_session_t session, lt_torrent_id id, int delete_files);
void          lt_set_download_limit(lt_session_t session, int bytes_per_sec);

/* status */
int lt_get_all_torrent_statuses(lt_session_t session, lt_torrent_status* out, int max_count);

#ifdef __cplusplus
}
#endif
