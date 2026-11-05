/* Decoder-local immutable draw metadata reuse. A key contains every byte of
 * the packed row, and the referenced depth object must compare equal. No GPU
 * objects, resource contents, capture identities or completion facts are cached.
 * The ordinary packet, row, schema, budget and downstream policy checks remain.
 * Owned by one serial chunk decoder; never shared between streams or threads. */
static BOOL ffst_replay_depth_equal(id a,id b,unsigned depth) {
    if(a==b)return YES;if(!a||!b||depth>64)return NO;
    CFTypeID type=CFGetTypeID((__bridge CFTypeRef)a);
    if(type!=CFGetTypeID((__bridge CFTypeRef)b))return NO;
    if(type==CFNumberGetTypeID())return !strcmp([a objCType],[b objCType])&&[a isEqual:b];
    if(type==CFDictionaryGetTypeID()){
        if([a count]!=[b count])return NO;
        for(id key in a)if(!ffst_replay_depth_equal(a[key],b[key],depth+1))return NO;
        return YES;
    }
    if(type==CFArrayGetTypeID()){
        if([a count]!=[b count])return NO;
        for(NSUInteger i=0;i<[a count];++i)if(!ffst_replay_depth_equal(a[i],b[i],depth+1))return NO;
        return YES;
    }
    return [a isEqual:b];
}
@implementation FFSTReplayDecodeCache {
    NSMutableDictionary<NSData *,NSArray *> *_rows;
    NSMutableArray<NSData *> *_order;
    NSMutableDictionary *_numbers;
    NSUInteger _cursor;
    uint64_t _hits,_misses,_evictions,_calls;
}
- (instancetype)init {
    self=[super init];if(self){_rows=[NSMutableDictionary new];
        _order=[NSMutableArray new];_numbers=[NSMutableDictionary new];}return self;
}
- (NSDictionary *)stats {
    return @{@"hits":@(_hits),@"misses":@(_misses),@"evictions":@(_evictions),
        @"entries":@(_rows.count),@"numbers":@(_numbers.count),@"calls":@(_calls)};
}
- (NSDictionary *)decode:(NSData *)wire {
    @try {
        if(![wire isKindOfClass:[NSData class]]||wire.length<sizeof(pr_header)||wire.length>PR_LIMIT)return nil;
        pr_header h;memcpy(&h,wire.bytes,sizeof(h));
        if(h.magic!=PR_MAGIC||h.version!=1||h.total!=wire.length||h.rows>PR_ROWS||
           h.row_bytes!=sizeof(pr_row)||h.header_bytes>wire.length-sizeof(h)||
           (uint64_t)h.rows*sizeof(pr_row)!=wire.length-sizeof(h)-h.header_bytes)return nil;
        NSData *json=[NSData dataWithBytes:(const uint8_t *)wire.bytes+sizeof(h) length:h.header_bytes];
        id object=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if(![object isKindOfClass:[NSDictionary class]]||object[@"draws"]||
           ![object[PR_DEPTH_KEY] isKindOfClass:[NSArray class]])return nil;
        NSArray *depths=object[PR_DEPTH_KEY];
        NSData *rows=[NSData dataWithBytes:(const uint8_t *)wire.bytes+sizeof(h)+h.header_bytes
            length:(NSUInteger)h.rows*sizeof(pr_row)];
        if(!pr_budget(json,rows,depths)||!pr_schema(object,rows))return nil;
        /* At most 13 distinct floating-point scalars per row. Reserve the
         * original normalizer's complete 4096-entry worst-case headroom. */
        if(_numbers.count>4096-13)[_numbers removeAllObjects];
        NSMutableArray *draws=[NSMutableArray arrayWithCapacity:h.rows];
        const uint8_t *bytes=rows.bytes;
        for(uint32_t i=0;i<h.rows;++i){
            pr_row row;memcpy(&row,bytes+i*sizeof(row),sizeof(row));
            if(_numbers.count>4096-13)[_numbers removeAllObjects];
            NSData *key=[NSData dataWithBytes:&row length:sizeof(row)];id depth=depths[row.depth];
            NSArray *entry=_rows[key];NSDictionary *draw=nil;
            if(entry&&ffst_replay_depth_equal(entry[0],depth,0)){draw=entry[1];++_hits;}
            else {
                draw=pr_row_dictionary(&row,depths,_numbers);if(!draw)return nil;++_misses;
                /* Bound retained depth input as well as row count. Oversized
                 * valid depth objects use the original uncached path. */
                NSData *depthBytes=[NSJSONSerialization dataWithJSONObject:@[depth] options:0 error:nil];
                if(depthBytes&&depthBytes.length<=4096){
                    if(!entry){
                        if(_order.count==1024){NSData *old=_order[_cursor];[_rows removeObjectForKey:old];
                            _order[_cursor]=key;_cursor=(_cursor+1)%1024;++_evictions;}
                        else [_order addObject:key];
                    }
                    _rows[key]=@[depth,draw];
                }
            }
            [draws addObject:draw];
        }
        NSMutableDictionary *result=[object mutableCopy];[result removeObjectForKey:PR_DEPTH_KEY];
        result[@"draws"]=[draws copy];++_calls;
        if(_calls<=2||!(_calls%256))fprintf(stderr,
            "[native-row-cache] hits=%llu misses=%llu evictions=%llu entries=%llu numbers=%llu calls=%llu\n",
            (unsigned long long)_hits,(unsigned long long)_misses,(unsigned long long)_evictions,
            (unsigned long long)_rows.count,(unsigned long long)_numbers.count,(unsigned long long)_calls);
        return [result copy];
    }@catch(__unused NSException *exception){return nil;}
}
@end
