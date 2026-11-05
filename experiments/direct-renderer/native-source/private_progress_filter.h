/* Private diagnostic-only output gate. The renderer retains its normal
 * internal objects; only the durable QA progress/result dictionaries change. */
static NSDictionary *private_progress_numbers(NSDictionary *source,NSArray<NSString *> *keys){
    NSMutableDictionary *out=[NSMutableDictionary dictionary];
    if(![source isKindOfClass:[NSDictionary class]])return out;
    for(NSString *key in keys){id value=source[key];
        if([value isKindOfClass:[NSNumber class]]&&isfinite([value doubleValue]))out[key]=value;}
    return out;
}
static NSDictionary *private_progress_output(NSDictionary *source){
    NSMutableDictionary *out=[private_progress_numbers(source,@[@"version",@"worker_pid",@"monotonic_seconds",
        @"chunks",@"frames",@"presentation_completed",@"presentation_errors",@"presentation_submitted",@"presentation_pending",
        @"presentation_cancelled",@"presentation_superseded",@"offscreen_gpu_completed",@"offscreen_snapshots_completed",
        @"texture_upload_bytes",@"texture_readback_bytes",@"readback_ranges",@"packet_bytes",@"decode_seconds",@"execute_seconds",
        @"completion_publish_seconds",@"prepared_limit",@"prepared_chunks",@"prepared_bytes",@"max_prepared_chunks",
        @"max_prepared_bytes",@"orderly_source_closed",@"native_prepare_seconds",@"native_encode_seconds",@"native_gpu_retire_seconds",
        @"shared_snapshot_buffers",@"shared_snapshot_buffer_bytes",@"receipt_mailbox_queued",@"receipt_mailbox_max_queued"]) mutableCopy];
    NSString *format=source[@"format"],*status=source[@"status"],*mode=source[@"render_mode"];
    if([format isEqual:@"bedrock-native-chunk-progress"]||[format isEqual:@"bedrock-native-chunk-worker"])out[@"format"]=format;
    if([status isEqual:@"completed"]||[status isEqual:@"failed"])out[@"status"]=status;
    if([mode isEqual:@"drawable"]||[mode isEqual:@"offscreen_gpu"])out[@"render_mode"]=mode;
    out[@"error"]=[source[@"error"] isKindOfClass:[NSString class]]&&[source[@"error"] length]?@"reported":@"";
    out[@"private_digest_peek"]=private_progress_numbers(source[@"private_digest_peek"],
        @[@"mode",@"successful_chunks",@"records",@"original_ns",@"deferred_ns",@"shadow_mismatches"]);
    out[@"last_frame"]=private_progress_numbers(source[@"last_frame"],@[@"width",@"height"]);
    out[@"native_render_profile"]=private_progress_numbers(source[@"native_render_profile"],@[@"coverage_seconds",@"decode_seconds",@"assets_seconds",
        @"pipeline_draw_seconds",@"tables_seconds",@"attachments_seconds",@"commands_seconds",@"native_operation_seconds",
        @"native_retirement_seconds",@"native_cleanup_seconds"]);
    out[@"actual_display"]=private_progress_numbers(source[@"actual_display"],@[@"enabled",@"scheduled",@"callbacks",@"positive",@"zero",@"invalid",
        @"unsupported",@"out_of_order",@"counter_overflow",@"first_presented_time",@"last_presented_time",@"intervals",
        @"interval_sum_seconds",@"lifetime_interval_max_seconds",@"intervals_over_25ms",@"intervals_over_50ms"]);
    return out;
}
