module mod_shapes_01_data_flow;

struct TRec_epochMs(T_epochMs) {
    T_epochMs epochMs;
}

struct TRec_hasNew_episodes_metadata(T_hasNew, T_episodes, T_metadata) {
    T_hasNew hasNew;
    T_episodes episodes;
    T_metadata metadata;
}

struct TRec_episodes(T_episodes) {
    T_episodes episodes;
}

struct TRec_url_timeout(T_url, T_timeout) {
    T_url url;
    T_timeout timeout;
}

struct TRec_trackId_title_durationMs(T_trackId, T_title, T_durationMs) {
    T_trackId trackId;
    T_title title;
    T_durationMs durationMs;
}

struct TRec_id_name_length(T_id, T_name, T_length) {
    T_id id;
    T_name name;
    T_length length;
}

