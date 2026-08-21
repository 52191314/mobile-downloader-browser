// aurora_torrent_bridge.cpp — BSD-3-Clause clean BitTorrent bridge.
// Original code for Aurora Download Manager (2026). Exposes a minimal C ABI
// (lt_*) to lib/torrent/aurora_torrent_engine.dart, backed by rasterbar
// libtorrent 2.1 (BSD-3-Clause). Not derived from the GPL libtorrent_flutter plugin.

#include "aurora_torrent_bridge.h"

#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/session_handle.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/settings_pack.hpp>

#include <mutex>
#include <memory>
#include <map>
#include <string>
#include <cstring>
#include <atomic>
#include <utility>
#include <vector>

namespace lt = libtorrent;

namespace {

struct SessionState {
    std::unique_ptr<lt::session> session;
    std::mutex mu;
    std::map<lt_torrent_id, lt::torrent_handle> handles;
    std::atomic<lt_torrent_id> next_id{1};
};

SessionState* g_state = nullptr;
std::mutex g_global_mu;

lt_torrent_id register_handle(SessionState* s, const lt::torrent_handle& h) {
    std::lock_guard<std::mutex> lk(s->mu);
    lt_torrent_id id = s->next_id.fetch_add(1);
    s->handles[id] = h;
    return id;
}

int map_state(const lt::torrent_status& st, int& is_paused) {
    if (st.flags & lt::torrent_flags::paused) {
        is_paused = 1;
        return LT_STATE_PAUSED;
    }
    switch (st.state) {
        case lt::torrent_status::checking_files:          return LT_STATE_CHECKING_FILES;
        case lt::torrent_status::downloading_metadata:    return LT_STATE_DOWNLOADING_META;
        case lt::torrent_status::downloading:             return LT_STATE_DOWNLOADING;
        case lt::torrent_status::finished:
        case lt::torrent_status::seeding:                 return LT_STATE_SEEDING;
        case lt::torrent_status::checking_resume_data:    return LT_STATE_CHECKING_RESUME;
        default:                                          return LT_STATE_DOWNLOADING;
    }
}

} // namespace

extern "C" {

lt_session_t lt_create_session(const char* save_path, int listen_port, int /*alert_mask*/) {
    (void)save_path;
    std::lock_guard<std::mutex> lk(g_global_mu);
    if (g_state) return g_state;

    auto* s = new SessionState();
    lt::settings_pack pack;
    // libtorrent 2.1 uses a listen_interfaces string; "0.0.0.0:<port>" binds
    // all interfaces on the requested port (0 = random, but keep caller's).
    std::string iface = "0.0.0.0:" + std::to_string(listen_port > 0 ? listen_port : 6881);
    pack.set_str(lt::settings_pack::listen_interfaces, iface);
    pack.set_bool(lt::settings_pack::enable_dht, true);
    pack.set_bool(lt::settings_pack::enable_lsd, true);
    pack.set_bool(lt::settings_pack::enable_upnp, true);
    pack.set_int(lt::settings_pack::alert_mask, 0);

    lt::session_params sp;
    sp.settings = pack;
    s->session = std::make_unique<lt::session>(std::move(sp));

    g_state = s;
    return s;
}

void lt_destroy_session(lt_session_t session) {
    if (!session) return;
    std::lock_guard<std::mutex> lk(g_global_mu);
    auto* s = static_cast<SessionState*>(session);
    if (s == g_state) g_state = nullptr;
    delete s;
}

lt_torrent_id lt_add_magnet(lt_session_t session, const char* magnet_uri, const char* save_path, int /*flags*/) {
    if (!session || !magnet_uri || !save_path) return -1;
    auto* s = static_cast<SessionState*>(session);

    lt::error_code ec;
    lt::add_torrent_params p = lt::parse_magnet_uri(magnet_uri, ec);
    if (ec) return -2;
    p.save_path = save_path;

    lt::torrent_handle h;
    try {
        h = s->session->add_torrent(p);
    } catch (const std::exception&) {
        return -3;
    }
    return register_handle(s, h);
}

lt_torrent_id lt_add_torrent_file(lt_session_t session, const char* file_path, const char* save_path, int /*flags*/) {
    if (!session || !file_path || !save_path) return -1;
    auto* s = static_cast<SessionState*>(session);

    lt::error_code ec;
    lt::load_torrent_limits limits;
    lt::add_torrent_params p = lt::load_torrent_file(std::string(file_path), ec, limits);
    if (ec || p.ti == nullptr || !p.ti->is_valid()) return -2;
    p.save_path = save_path;

    lt::torrent_handle h;
    try {
        h = s->session->add_torrent(p);
    } catch (const std::exception&) {
        return -3;
    }
    return register_handle(s, h);
}

void lt_pause_torrent(lt_session_t session, lt_torrent_id id) {
    if (!session) return;
    auto* s = static_cast<SessionState*>(session);
    std::lock_guard<std::mutex> lk(s->mu);
    auto it = s->handles.find(id);
    if (it != s->handles.end()) it->second.pause();
}

void lt_resume_torrent(lt_session_t session, lt_torrent_id id) {
    if (!session) return;
    auto* s = static_cast<SessionState*>(session);
    std::lock_guard<std::mutex> lk(s->mu);
    auto it = s->handles.find(id);
    if (it != s->handles.end()) it->second.resume();
}

void lt_remove_torrent(lt_session_t session, lt_torrent_id id, int delete_files) {
    if (!session) return;
    auto* s = static_cast<SessionState*>(session);
    lt::torrent_handle h;
    {
        std::lock_guard<std::mutex> lk(s->mu);
        auto it = s->handles.find(id);
        if (it != s->handles.end()) { h = it->second; s->handles.erase(it); }
    }
    if (h.is_valid()) {
        lt::remove_flags_t flags = delete_files ? lt::session_handle::delete_files
                                                : lt::remove_flags_t{};
        s->session->remove_torrent(h, flags);
    }
}

void lt_set_download_limit(lt_session_t session, int bytes_per_sec) {
    if (!session) return;
    auto* s = static_cast<SessionState*>(session);
    lt::settings_pack pack;
    pack.set_int(lt::settings_pack::download_rate_limit, bytes_per_sec);
    s->session->apply_settings(pack);
}

int lt_get_all_torrent_statuses(lt_session_t session, lt_torrent_status* out, int max_count) {
    if (!session || !out || max_count <= 0) return 0;
    auto* s = static_cast<SessionState*>(session);

    std::lock_guard<std::mutex> lk(s->mu);
    int n = 0;
    for (auto& kv : s->handles) {
        lt_torrent_id id = kv.first;
        lt::torrent_handle& h = kv.second;
        if (n >= max_count) break;
        if (!h.is_valid()) continue;

        lt::torrent_status st = h.status();
        lt_torrent_status& o = out[n];
        std::memset(&o, 0, sizeof(o));

        o.id = id;
        o.state = LT_STATE_DOWNLOADING;
        std::string name = h.status().name;
        if (!name.empty()) {
            std::strncpy(o.name, name.c_str(), sizeof(o.name) - 1);
        }
        std::string sp = st.save_path;
        if (!sp.empty()) {
            std::strncpy(o.save_path, sp.c_str(), sizeof(o.save_path) - 1);
        }

        int is_paused = 0;
        o.state = map_state(st, is_paused);
        o.is_paused = is_paused;

        if (st.errc) {
            o.state = LT_STATE_ERROR;
            std::strncpy(o.error_msg, st.errc.message().c_str(), sizeof(o.error_msg) - 1);
        }

        o.progress       = st.progress;
        o.download_rate  = static_cast<int32_t>(st.download_payload_rate);
        o.upload_rate    = static_cast<int32_t>(st.upload_payload_rate);
        o.total_done     = static_cast<int64_t>(st.total_done);
        o.total_wanted   = static_cast<int64_t>(st.total_wanted);
        o.total_uploaded = static_cast<int64_t>(st.total_payload_upload);
        o.num_peers      = static_cast<int32_t>(st.num_peers);
        o.num_seeds      = static_cast<int32_t>(st.num_seeds);
        o.num_pieces     = static_cast<int32_t>(st.num_pieces);
        o.pieces_done    = static_cast<int32_t>(st.num_pieces == 0 ? 0 : st.progress * st.num_pieces);
        o.is_finished    = (st.state == lt::torrent_status::seeding ||
                            st.state == lt::torrent_status::finished) ? 1 : 0;
        o.has_metadata   = st.has_metadata ? 1 : 0;
        o.queue_position = 0;

        ++n;
    }
    return n;
}

} // extern "C"
