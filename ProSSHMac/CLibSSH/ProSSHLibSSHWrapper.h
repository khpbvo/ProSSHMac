#ifndef ProSSHLibSSHWrapper_h
#define ProSSHLibSSHWrapper_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ProSSHLibSSHHandle ProSSHLibSSHHandle;

typedef enum ProSSHAuthMethod {
    PROSSH_AUTH_PASSWORD = 0,
    PROSSH_AUTH_PUBLICKEY = 1,
    PROSSH_AUTH_CERTIFICATE = 2,
    PROSSH_AUTH_KEYBOARD_INTERACTIVE = 3
} ProSSHAuthMethod;

typedef enum ProSSHKeyAlgorithm {
    PROSSH_KEY_RSA = 0,
    PROSSH_KEY_ED25519 = 1,
    PROSSH_KEY_ECDSA_P256 = 2,
    PROSSH_KEY_ECDSA_P384 = 3,
    PROSSH_KEY_ECDSA_P521 = 4,
    PROSSH_KEY_DSA = 5
} ProSSHKeyAlgorithm;

typedef enum ProSSHPrivateKeyFormat {
    PROSSH_PRIVATE_KEY_OPENSSH = 0,
    PROSSH_PRIVATE_KEY_PEM = 1,
    PROSSH_PRIVATE_KEY_PKCS8 = 2
} ProSSHPrivateKeyFormat;

typedef enum ProSSHPrivateKeyCipher {
    PROSSH_PRIVATE_KEY_CIPHER_NONE = 0,
    PROSSH_PRIVATE_KEY_CIPHER_AES256CTR = 1,
    PROSSH_PRIVATE_KEY_CIPHER_CHACHA20_POLY1305 = 2
} ProSSHPrivateKeyCipher;

ProSSHLibSSHHandle *prossh_libssh_create(void);
void prossh_libssh_destroy(ProSSHLibSSHHandle *handle);

int prossh_libssh_connect(
    ProSSHLibSSHHandle *handle,
    const char *hostname,
    uint16_t port,
    const char *username,
    const char *kex,
    const char *ciphers,
    const char *hostkeys,
    const char *macs,
    int timeout_seconds,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_authenticate(
    ProSSHLibSSHHandle *handle,
    ProSSHAuthMethod auth_method,
    const char *password,
    const char *private_key,
    const char *certificate,
    const char *key_passphrase,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_get_negotiated(
    ProSSHLibSSHHandle *handle,
    char *kex_buffer,
    size_t kex_buffer_len,
    char *cipher_buffer,
    size_t cipher_buffer_len,
    char *hostkey_buffer,
    size_t hostkey_buffer_len,
    char *fingerprint_buffer,
    size_t fingerprint_buffer_len
);

int prossh_libssh_open_shell(
    ProSSHLibSSHHandle *handle,
    int columns,
    int rows,
    const char *terminal_type,
    bool enable_agent_forwarding,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_channel_write(
    ProSSHLibSSHHandle *handle,
    const char *input,
    size_t input_len,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_channel_read(
    ProSSHLibSSHHandle *handle,
    char *output_buffer,
    size_t output_buffer_len,
    int *bytes_read,
    bool *is_eof,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_generate_keypair(
    ProSSHKeyAlgorithm algorithm,
    int parameter,
    ProSSHPrivateKeyFormat private_key_format,
    const char *passphrase,
    ProSSHPrivateKeyCipher private_key_cipher,
    const char *comment,
    char *private_key_buffer,
    size_t private_key_buffer_len,
    char *public_key_buffer,
    size_t public_key_buffer_len,
    char *sha256_fingerprint_buffer,
    size_t sha256_fingerprint_buffer_len,
    char *md5_fingerprint_buffer,
    size_t md5_fingerprint_buffer_len,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_import_key(
    const char *key_input,
    const char *passphrase,
    const char *comment,
    char *private_key_buffer,
    size_t private_key_buffer_len,
    char *public_key_buffer,
    size_t public_key_buffer_len,
    char *key_type_buffer,
    size_t key_type_buffer_len,
    int *bit_length,
    int *is_private_key,
    int *is_passphrase_protected,
    int *detected_private_format,
    int *detected_private_cipher,
    char *sha256_fingerprint_buffer,
    size_t sha256_fingerprint_buffer_len,
    char *md5_fingerprint_buffer,
    size_t md5_fingerprint_buffer_len,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_convert_private_key(
    const char *private_key_input,
    const char *input_passphrase,
    ProSSHPrivateKeyFormat output_private_key_format,
    const char *output_passphrase,
    ProSSHPrivateKeyCipher output_private_key_cipher,
    const char *comment,
    char *private_key_buffer,
    size_t private_key_buffer_len,
    char *public_key_buffer,
    size_t public_key_buffer_len,
    char *sha256_fingerprint_buffer,
    size_t sha256_fingerprint_buffer_len,
    char *md5_fingerprint_buffer,
    size_t md5_fingerprint_buffer_len,
    int *output_is_passphrase_protected,
    int *output_private_cipher,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_copy_public_key_to_host(
    const char *hostname,
    uint16_t port,
    const char *username,
    const char *password,
    const char *public_key_authorized,
    const char *private_key_for_verification,
    const char *private_key_passphrase,
    const char *kex,
    const char *ciphers,
    const char *hostkeys,
    const char *macs,
    int timeout_seconds,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_sftp_list_directory(
    ProSSHLibSSHHandle *handle,
    const char *remote_path,
    char *output_buffer,
    size_t output_buffer_len,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_sftp_download_file(
    ProSSHLibSSHHandle *handle,
    const char *remote_path,
    const char *local_path,
    int64_t *bytes_transferred,
    int64_t *total_bytes,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_sftp_upload_file(
    ProSSHLibSSHHandle *handle,
    const char *local_path,
    const char *remote_path,
    int64_t *bytes_transferred,
    int64_t *total_bytes,
    char *error_buffer,
    size_t error_buffer_len
);

typedef struct ProSSHJumpHostConfig {
    const char *jump_hostname;
    const char *jump_username;
    uint16_t jump_port;
    const char *kex;
    const char *ciphers;
    const char *hostkeys;
    const char *macs;
    int timeout_seconds;
    const char *expected_fingerprint;
    ProSSHAuthMethod auth_method;
    const char *password;
    const char *private_key;
    const char *certificate;
    const char *key_passphrase;
    int verify_result;
    char actual_fingerprint[256];
    int auth_result;
    char callback_error[512];
} ProSSHJumpHostConfig;

int prossh_libssh_connect_with_jump(
    ProSSHLibSSHHandle *handle,
    const char *hostname,
    uint16_t port,
    const char *username,
    const char *kex,
    const char *ciphers,
    const char *hostkeys,
    const char *macs,
    int timeout_seconds,
    ProSSHJumpHostConfig *jump_config,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_channel_resize_pty(
    ProSSHLibSSHHandle *handle,
    int columns,
    int rows,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_libssh_send_keepalive(ProSSHLibSSHHandle *handle);

void prossh_libssh_channel_close(ProSSHLibSSHHandle *handle);
void prossh_libssh_disconnect(ProSSHLibSSHHandle *handle);

typedef struct ProSSHForwardChannel ProSSHForwardChannel;

ProSSHForwardChannel *prossh_forward_channel_open(
    ProSSHLibSSHHandle *handle,
    const char *remote_host,
    uint16_t remote_port,
    const char *source_host,
    uint16_t source_port,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_forward_channel_read(
    ProSSHForwardChannel *fwd,
    char *buffer,
    size_t buffer_len,
    bool *is_eof,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_forward_channel_write(
    ProSSHForwardChannel *fwd,
    const char *data,
    size_t data_len,
    char *error_buffer,
    size_t error_buffer_len
);

int prossh_forward_channel_is_open(ProSSHForwardChannel *fwd);

void prossh_forward_channel_close(ProSSHForwardChannel *fwd);

#endif /* ProSSHLibSSHWrapper_h */
