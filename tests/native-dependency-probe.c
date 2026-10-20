/* Local dependency probe: no game/account code. Original project code GPLv3. */
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <sys/socket.h>
#include <sys/time.h>
#include <netdb.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define REQUIRE(c,m) do { if (!(c)) { fprintf(stderr,"FAIL: %s\n",m); return 1; } } while(0)
int main(int argc,char **argv) {
    REQUIRE(argc==2,"font path required");
    REQUIRE(gnutls_global_init()==0,"GnuTLS init");
    unsigned char hash[32]; const unsigned char expected[32]={0xba,0x78,0x16,0xbf,0x8f,0x01,0xcf,0xea,0x41,0x41,0x40,0xde,0x5d,0xae,0x22,0x23,0xb0,0x03,0x61,0xa3,0x96,0x17,0x7a,0x9c,0xb4,0x10,0xff,0x61,0xf2,0x00,0x15,0xad};
    REQUIRE(gnutls_hash_fast(GNUTLS_DIG_SHA256,"abc",3,hash)==0 && !memcmp(hash,expected,32),"SHA256 known vector");
    FT_Library library; FT_Face face; int major,minor,patch;
    REQUIRE(FT_Init_FreeType(&library)==0,"FreeType init");
    FT_Library_Version(library,&major,&minor,&patch);
    REQUIRE(FT_New_Face(library,argv[1],0,&face)==0,"font loading");
    REQUIRE(FT_Set_Pixel_Sizes(face,0,24)==0 && FT_Load_Char(face,'A',FT_LOAD_RENDER)==0,"glyph render");
    REQUIRE(face->glyph->bitmap.width>0 && face->glyph->bitmap.rows>0,"glyph pixels");
    printf("FreeType %d.%d.%d glyph=%ux%u\n",major,minor,patch,face->glyph->bitmap.width,face->glyph->bitmap.rows);
    FT_Done_Face(face); FT_Done_FreeType(library);
    const char *host="dlassets-ssl.xboxlive.com";
    struct addrinfo hints={0},*addresses=0; hints.ai_socktype=SOCK_STREAM;
    REQUIRE(getaddrinfo(host,"443",&hints,&addresses)==0,"DNS"); int fd=-1;
    for(struct addrinfo *a=addresses;a;a=a->ai_next){fd=socket(a->ai_family,a->ai_socktype,a->ai_protocol);if(fd<0)continue; struct timeval timeout={15,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));if(connect(fd,a->ai_addr,a->ai_addrlen)==0)break;close(fd);fd=-1;}
    freeaddrinfo(addresses); REQUIRE(fd>=0,"TLS socket");
    gnutls_certificate_credentials_t credentials;gnutls_session_t session;
    REQUIRE(gnutls_certificate_allocate_credentials(&credentials)==0,"certificate credentials");
    REQUIRE(gnutls_certificate_set_x509_system_trust(credentials)>0,"system trust roots");
    REQUIRE(gnutls_init(&session,GNUTLS_CLIENT)==0 && gnutls_set_default_priority(session)==0,"TLS setup");
    REQUIRE(gnutls_credentials_set(session,GNUTLS_CRD_CERTIFICATE,credentials)==0,"TLS credentials");
    REQUIRE(gnutls_server_name_set(session,GNUTLS_NAME_DNS,host,strlen(host))==0,"TLS hostname");
    gnutls_transport_set_int(session,fd);gnutls_handshake_set_timeout(session,15000);
    REQUIRE(gnutls_handshake(session)==0,"TLS handshake");unsigned status=0;
    REQUIRE(gnutls_certificate_verify_peers3(session,host,&status)==0 && status==0,"certificate chain and hostname verification");
    REQUIRE(gnutls_certificate_verify_peers3(session,"wrong-host.invalid",&status)==0 && status!=0,"wrong hostname rejection");
    const char request[]="GET /Z/routing/up.txt HTTP/1.1\r\nHost: dlassets-ssl.xboxlive.com\r\nConnection: close\r\n\r\n";
    REQUIRE(gnutls_record_send(session,request,sizeof(request)-1)>0,"TLS request");char response[4096]={0};int n=GNUTLS_E_AGAIN;
    for(int attempt=0;attempt<10 && (n==GNUTLS_E_AGAIN || n==GNUTLS_E_INTERRUPTED);attempt++) n=gnutls_record_recv(session,response,sizeof(response)-1);
    if(n<=0) fprintf(stderr,"TLS read status=%d (%s)\n",n,gnutls_strerror(n));
    else { char *end=strstr(response,"\r\n"); if(end)*end=0; fprintf(stderr,"HTTPS status line: %s\n",response); }
    REQUIRE(n>0 && strstr(response," 200"),"authenticated HTTPS response");
    printf("GnuTLS %s SHA256=pass TLS-chain-and-host=pass wrong-host=rejected HTTPS=200\n",gnutls_check_version(NULL));
    gnutls_bye(session,GNUTLS_SHUT_WR);gnutls_deinit(session);gnutls_certificate_free_credentials(credentials);close(fd);gnutls_global_deinit();return 0;
}
