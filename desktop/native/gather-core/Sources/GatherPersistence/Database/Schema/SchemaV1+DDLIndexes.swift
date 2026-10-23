// desktop/native/gather-core/Sources/GatherPersistence/Database/Schema/SchemaV1+DDLIndexes.swift
// SchemaV1 DDL 片段 3/3：69 个显式索引（61 普通 + 8 UNIQUE）。
//
// 字面量以空行开头：该空行即原 DDL 中表 43 与索引段之间的空行，前面的拼接换行
// 是表 43 末行的换行；本片段必须固定在最后（ddlCore → ddlDomain → ddlIndexes）。
extension SchemaV1 {
    /// DDL 片段 3/3（internal：仅供 SchemaV1.ddl 拼接，不是公开 API）。
    static let ddlIndexes: String = """

    -- ─────────────────────────────── 索引 ───────────────────────────────
    -- photos
    CREATE UNIQUE INDEX idx_photos_session_filepath ON photos(session_id, filepath);
    CREATE INDEX idx_photos_filepath ON photos(filepath);
    CREATE INDEX idx_photos_created_at ON photos(created_at);
    CREATE INDEX idx_photos_asset ON photos(asset_id);
    CREATE INDEX idx_photos_asset_file ON photos(asset_file_id);
    CREATE INDEX idx_photos_asset_group ON photos(session_id, COALESCE(NULLIF(asset_id, ''), id));

    -- asset_files / assets / 关系表
    CREATE UNIQUE INDEX idx_asset_files_volume_path ON asset_files(volume_id, normalized_path);
    CREATE UNIQUE INDEX idx_asset_files_volume_identity
      ON asset_files(volume_id, file_identity) WHERE file_identity != '';
    CREATE INDEX idx_asset_files_checksum ON asset_files(checksum);
    CREATE INDEX idx_asset_files_volume_status ON asset_files(volume_id, online_status);
    CREATE INDEX idx_asset_candidates_relation_status ON asset_link_candidates(relation_type, status);
    CREATE INDEX idx_asset_candidates_left ON asset_link_candidates(left_file_id);
    CREATE INDEX idx_asset_candidates_right ON asset_link_candidates(right_file_id);
    CREATE INDEX idx_session_assets_asset ON session_assets(asset_id);
    CREATE INDEX idx_sidecar_binding_files_file ON sidecar_binding_files(file_id);

    -- analysis
    CREATE INDEX idx_analysis_jobs_status_priority ON analysis_jobs(status, priority, updated_at);
    CREATE INDEX idx_analysis_jobs_scope ON analysis_jobs(scope_type, scope_id);
    CREATE INDEX idx_analysis_runs_session_kind ON analysis_runs(session_id, kind, status, id DESC);
    CREATE UNIQUE INDEX idx_analysis_jobs_active_dedupe
      ON analysis_jobs(dedupe_key)
      WHERE status IN ('queued', 'running', 'cancelling');
    CREATE INDEX idx_asset_analysis_photo_type ON asset_analysis(photo_id, analysis_type);
    CREATE INDEX idx_asset_analysis_file_type ON asset_analysis(asset_file_id, analysis_type);

    -- face
    CREATE INDEX idx_face_observations_session ON face_observations(session_id);
    CREATE INDEX idx_face_observations_photo ON face_observations(photo_id);
    CREATE INDEX idx_face_analysis_state_session ON face_analysis_state(session_id);
    CREATE INDEX idx_face_identity_feedback_session ON face_identity_feedback(session_id, photo_id);
    CREATE INDEX idx_face_identity_feedback_photo ON face_identity_feedback(photo_id);
    CREATE INDEX idx_face_identity_feedback_person ON face_identity_feedback(person_id);
    CREATE INDEX idx_face_clusters_session ON face_clusters(session_id);
    CREATE INDEX idx_face_clusters_matched_person ON face_clusters(matched_person_id);
    CREATE INDEX idx_face_cluster_members_cluster ON face_cluster_members(cluster_id);
    CREATE INDEX idx_face_cluster_members_session ON face_cluster_members(session_id);
    CREATE INDEX idx_face_cluster_members_photo ON face_cluster_members(photo_id);
    CREATE INDEX idx_face_cluster_members_observation ON face_cluster_members(observation_id);
    CREATE INDEX idx_role_bindings_session ON role_bindings(session_id);

    -- similarity
    CREATE INDEX idx_similarity_hashes_photo ON similarity_hashes(photo_id);
    CREATE UNIQUE INDEX idx_similarity_hashes_session_photo ON similarity_hashes(session_id, photo_id);
    CREATE INDEX idx_similarity_results_session ON similarity_results(session_id);
    CREATE INDEX idx_similarity_members_session_photo ON similarity_result_members(session_id, photo_id);
    CREATE INDEX idx_similarity_members_result_group ON similarity_result_members(result_id, group_index);
    CREATE INDEX idx_similarity_members_photo ON similarity_result_members(photo_id);

    -- persons
    CREATE INDEX idx_persons_name ON persons(name);
    CREATE INDEX idx_person_embeddings_person ON person_embeddings(person_id);
    CREATE UNIQUE INDEX idx_person_embeddings_obs ON person_embeddings(face_observation_id);
    CREATE INDEX idx_person_embeddings_photo ON person_embeddings(photo_id);
    CREATE INDEX idx_person_embeddings_session ON person_embeddings(session_id);
    CREATE INDEX idx_person_photos_photo ON person_photos(photo_id);
    CREATE INDEX idx_person_photos_session ON person_photos(session_id);
    CREATE UNIQUE INDEX idx_person_photos_person_photo ON person_photos(person_id, photo_id);

    -- metadata cache
    CREATE INDEX idx_metadata_cache_session ON photo_metadata_cache(session_id);
    CREATE INDEX idx_metadata_cache_session_date ON photo_metadata_cache(session_id, date_taken);
    CREATE INDEX idx_metadata_cache_session_rating ON photo_metadata_cache(session_id, rating);
    CREATE INDEX idx_metadata_cache_session_label ON photo_metadata_cache(session_id, label);
    CREATE INDEX idx_metadata_cache_camera_make ON photo_metadata_cache(camera_make);

    -- duplicates / culling / navigation
    CREATE INDEX idx_duplicate_groups_session ON duplicate_groups(session_id);
    CREATE INDEX idx_duplicate_members_group ON duplicate_group_members(group_id);
    CREATE INDEX idx_duplicate_members_photo ON duplicate_group_members(photo_id);
    CREATE INDEX idx_duplicate_members_session ON duplicate_group_members(session_id);
    CREATE UNIQUE INDEX idx_culling_session_photo_unique ON culling_decisions(session_id, photo_id);
    CREATE INDEX idx_culling_group ON culling_decisions(session_id, group_id);
    CREATE INDEX idx_culling_decisions_photo ON culling_decisions(photo_id);
    CREATE INDEX idx_culling_history_session ON culling_history(session_id, id);
    CREATE INDEX idx_navigation_groups_session_type ON navigation_groups(session_id, group_type, updated_at);
    CREATE INDEX idx_navigation_groups_lead ON navigation_groups(lead_photo_id);
    CREATE INDEX idx_metadata_keyword_origins_source_active
      ON metadata_keyword_origins(source, active, updated_at);

    -- delivery
    CREATE INDEX idx_deliveries_status ON deliveries(status, updated_at);
    CREATE INDEX idx_delivery_sessions_session ON delivery_sessions(session_id, delivery_id);
    CREATE INDEX idx_delivery_items_photo ON delivery_items(photo_id);
    CREATE INDEX idx_delivery_items_module_status ON delivery_items(module, status);
    CREATE INDEX idx_delivery_intents_phase ON delivery_intents(phase, id);

    """
}
