#include "ProSSHLibSSHWrapper.h"

#include <libssh/libssh.h>
#include <libssh/callbacks.h>
#include <libssh/sftp.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/err.h>

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdint.h>

struct ProSSHLibSSHHandle {
    ssh_session session;
    ssh_channel channel;
};

struct ProSSHForwardChannel {
    ssh_channel channel;
};

int ssh_pki_export_pubkey_blob(const ssh_key key, ssh_string *pblob);
int ssh_pki_export_privkey_blob(const ssh_key key, ssh_string *pblob);
int ssh_key_size(ssh_key key);
int bcrypt_pbkdf(
    const char *pass,
    size_t passlen,
    const uint8_t *salt,
    size_t saltlen,
    uint8_t *key,
    size_t keylen,
    unsigned int rounds
);
static char *prossh_trimmed_copy(const char *text);
static int prossh_parse_public_key_tokens(
    const char *text,
    char **type_token,
    char **base64_token
);

static void prossh_copy_string(char *dst, size_t dst_len, const char *src) {
    if (dst == NULL || dst_len == 0) {
        return;
    }

    if (src == NULL) {
        dst[0] = '\0';
        return;
    }

    snprintf(dst, dst_len, "%s", src);
}

static void prossh_append_pty_mode(
    unsigned char *buffer,
    size_t *offset,
    size_t capacity,
    unsigned char opcode,
    uint32_t value
) {
    if (buffer == NULL || offset == NULL) {
        return;
    }
    if (*offset + 5 > capacity) {
        return;
    }

    buffer[*offset] = opcode;
    (*offset)++;
    buffer[*offset] = (unsigned char)((value >> 24) & 0xFF);
    (*offset)++;
    buffer[*offset] = (unsigned char)((value >> 16) & 0xFF);
    (*offset)++;
    buffer[*offset] = (unsigned char)((value >> 8) & 0xFF);
    (*offset)++;
    buffer[*offset] = (unsigned char)(value & 0xFF);
    (*offset)++;
}

static void prossh_secure_clear(void *buffer, size_t length) {
    if (buffer == NULL || length == 0) {
        return;
    }

    volatile unsigned char *cursor = (volatile unsigned char *)buffer;
    while (length > 0) {
        *cursor = 0;
        cursor++;
        length--;
    }
}

static void prossh_secure_clear_cstring(char *value) {
    if (value == NULL) {
        return;
    }
    prossh_secure_clear(value, strlen(value));
}

static void prossh_secure_free_cstring(char *value) {
    if (value == NULL) {
        return;
    }
    prossh_secure_clear_cstring(value);
    free(value);
}

static void prossh_set_error(
    ProSSHLibSSHHandle *handle,
    const char *fallback,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (handle != NULL && handle->session != NULL) {
        const char *session_error = ssh_get_error(handle->session);
        if (session_error != NULL && session_error[0] != '\0') {
            prossh_copy_string(error_buffer, error_buffer_len, session_error);
            return;
        }
    }

    prossh_copy_string(error_buffer, error_buffer_len, fallback);
}

static int prossh_apply_options(
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
) {
    if (ssh_options_set(handle->session, SSH_OPTIONS_HOST, hostname) != SSH_OK) {
        prossh_set_error(handle, "Failed to set host option", error_buffer, error_buffer_len);
        return -1;
    }

    int numeric_port = (int)port;
    if (ssh_options_set(handle->session, SSH_OPTIONS_PORT, &numeric_port) != SSH_OK) {
        prossh_set_error(handle, "Failed to set port option", error_buffer, error_buffer_len);
        return -1;
    }

    if (ssh_options_set(handle->session, SSH_OPTIONS_USER, username) != SSH_OK) {
        prossh_set_error(handle, "Failed to set username option", error_buffer, error_buffer_len);
        return -1;
    }

    int strict_host_key_check = 0;
    if (ssh_options_set(handle->session, SSH_OPTIONS_STRICTHOSTKEYCHECK, &strict_host_key_check) != SSH_OK) {
        prossh_set_error(handle, "Failed to configure host key verification mode", error_buffer, error_buffer_len);
        return -1;
    }

    if (timeout_seconds > 0) {
        long timeout = (long)timeout_seconds;
        if (ssh_options_set(handle->session, SSH_OPTIONS_TIMEOUT, &timeout) != SSH_OK) {
            prossh_set_error(handle, "Failed to set timeout option", error_buffer, error_buffer_len);
            return -1;
        }
    }

    if (kex != NULL && kex[0] != '\0') {
        if (ssh_options_set(handle->session, SSH_OPTIONS_KEY_EXCHANGE, kex) != SSH_OK) {
            prossh_set_error(handle, "Failed to set key-exchange algorithms", error_buffer, error_buffer_len);
            return -1;
        }
    }

    if (ciphers != NULL && ciphers[0] != '\0') {
        if (ssh_options_set(handle->session, SSH_OPTIONS_CIPHERS_C_S, ciphers) != SSH_OK ||
            ssh_options_set(handle->session, SSH_OPTIONS_CIPHERS_S_C, ciphers) != SSH_OK) {
            prossh_set_error(handle, "Failed to set ciphers", error_buffer, error_buffer_len);
            return -1;
        }
    }

    if (hostkeys != NULL && hostkeys[0] != '\0') {
        if (ssh_options_set(handle->session, SSH_OPTIONS_HOSTKEYS, hostkeys) != SSH_OK) {
            prossh_set_error(handle, "Failed to set host key algorithms", error_buffer, error_buffer_len);
            return -1;
        }
    }

    if (macs != NULL && macs[0] != '\0') {
        if (ssh_options_set(handle->session, SSH_OPTIONS_HMAC_C_S, macs) != SSH_OK ||
            ssh_options_set(handle->session, SSH_OPTIONS_HMAC_S_C, macs) != SSH_OK) {
            prossh_set_error(handle, "Failed to set MAC algorithms", error_buffer, error_buffer_len);
            return -1;
        }
    }

    return 0;
}

static int prossh_authenticate(
    ProSSHLibSSHHandle *handle,
    ProSSHAuthMethod auth_method,
    const char *password,
    const char *private_key_text,
    const char *certificate_text,
    const char *key_passphrase,
    char *error_buffer,
    size_t error_buffer_len
) {
    int auth_result = SSH_AUTH_ERROR;

    if (auth_method == PROSSH_AUTH_PASSWORD) {
        if (password == NULL || password[0] == '\0') {
            prossh_copy_string(error_buffer, error_buffer_len, "Password authentication selected but no password was provided.");
            return -1;
        }

        auth_result = ssh_userauth_password(handle->session, NULL, password);
        if (auth_result == SSH_AUTH_SUCCESS) {
            return 0;
        }

        prossh_set_error(handle, "Password authentication failed", error_buffer, error_buffer_len);
        return -1;
    }

    if (auth_method == PROSSH_AUTH_KEYBOARD_INTERACTIVE) {
        auth_result = ssh_userauth_kbdint(handle->session, NULL, NULL);
        while (auth_result == SSH_AUTH_INFO) {
            int prompts = ssh_userauth_kbdint_getnprompts(handle->session);
            for (int i = 0; i < prompts; i++) {
                ssh_userauth_kbdint_setanswer(handle->session, i, "");
            }
            auth_result = ssh_userauth_kbdint(handle->session, NULL, NULL);
        }

        if (auth_result == SSH_AUTH_SUCCESS) {
            return 0;
        }

        prossh_set_error(handle, "Keyboard-interactive authentication failed", error_buffer, error_buffer_len);
        return -1;
    }

    const char *effective_key_passphrase = key_passphrase;
    if (effective_key_passphrase != NULL && effective_key_passphrase[0] == '\0') {
        effective_key_passphrase = NULL;
    }

    if (private_key_text != NULL && private_key_text[0] != '\0') {
        char *normalized_private_key = prossh_trimmed_copy(private_key_text);
        ssh_key private_key = NULL;
        ssh_key cert_key = NULL;
        int return_code = -1;

        if (normalized_private_key == NULL || normalized_private_key[0] == '\0') {
            prossh_secure_free_cstring(normalized_private_key);
            prossh_copy_string(error_buffer, error_buffer_len, "No private key text was provided for authentication.");
            return -1;
        }

        int import_private_key_result = ssh_pki_import_privkey_base64(
            normalized_private_key,
            effective_key_passphrase,
            NULL,
            NULL,
            &private_key
        );
        if (import_private_key_result != SSH_OK || private_key == NULL) {
            prossh_secure_free_cstring(normalized_private_key);
            if (auth_method == PROSSH_AUTH_CERTIFICATE) {
                prossh_copy_string(
                    error_buffer,
                    error_buffer_len,
                    "Failed to import private key for certificate authentication. Verify key format and passphrase."
                );
            } else {
                prossh_copy_string(
                    error_buffer,
                    error_buffer_len,
                    "Failed to import private key for public-key authentication. Verify key format and passphrase."
                );
            }
            return -1;
        }

        if (auth_method == PROSSH_AUTH_CERTIFICATE) {
            char *cert_type_token = NULL;
            char *cert_base64_token = NULL;

            int parse_result = prossh_parse_public_key_tokens(
                certificate_text,
                &cert_type_token,
                &cert_base64_token
            );
            if (parse_result != 0) {
                prossh_copy_string(
                    error_buffer,
                    error_buffer_len,
                    "Certificate authentication requires an OpenSSH certificate in authorized format."
                );
                free(cert_type_token);
                free(cert_base64_token);
                ssh_key_free(private_key);
                prossh_secure_free_cstring(normalized_private_key);
                return -1;
            }

            enum ssh_keytypes_e cert_type = ssh_key_type_from_name(cert_type_token);
            if (cert_type == SSH_KEYTYPE_UNKNOWN) {
                prossh_copy_string(error_buffer, error_buffer_len, "Unsupported SSH certificate key type.");
                free(cert_type_token);
                free(cert_base64_token);
                ssh_key_free(private_key);
                prossh_secure_free_cstring(normalized_private_key);
                return -1;
            }

            int import_cert_result = ssh_pki_import_cert_base64(cert_base64_token, cert_type, &cert_key);
            free(cert_type_token);
            free(cert_base64_token);
            if (import_cert_result != SSH_OK || cert_key == NULL) {
                prossh_copy_string(error_buffer, error_buffer_len, "Failed to import SSH certificate.");
                ssh_key_free(private_key);
                prossh_secure_free_cstring(normalized_private_key);
                return -1;
            }

            if (ssh_pki_copy_cert_to_privkey(cert_key, private_key) != SSH_OK) {
                prossh_copy_string(error_buffer, error_buffer_len, "Failed to bind certificate to private key.");
                ssh_key_free(cert_key);
                ssh_key_free(private_key);
                prossh_secure_free_cstring(normalized_private_key);
                return -1;
            }
        }

        auth_result = ssh_userauth_publickey(handle->session, NULL, private_key);
        if (auth_result == SSH_AUTH_SUCCESS) {
            return_code = 0;
        } else if (auth_method == PROSSH_AUTH_CERTIFICATE) {
            prossh_set_error(handle, "Certificate authentication failed", error_buffer, error_buffer_len);
        } else {
            prossh_set_error(handle, "Public-key authentication failed", error_buffer, error_buffer_len);
        }

        ssh_key_free(cert_key);
        ssh_key_free(private_key);
        prossh_secure_free_cstring(normalized_private_key);
        return return_code;
    }

    auth_result = ssh_userauth_publickey_auto(handle->session, NULL, effective_key_passphrase);
    if (auth_result != SSH_AUTH_SUCCESS) {
        if (auth_method == PROSSH_AUTH_CERTIFICATE) {
            prossh_set_error(handle, "Certificate authentication failed", error_buffer, error_buffer_len);
        } else {
            prossh_set_error(handle, "Public-key authentication failed", error_buffer, error_buffer_len);
        }
        return -1;
    }

    return 0;
}

static enum ssh_keytypes_e prossh_map_key_algorithm(ProSSHKeyAlgorithm algorithm) {
    switch (algorithm) {
        case PROSSH_KEY_RSA:
            return SSH_KEYTYPE_RSA;
        case PROSSH_KEY_ED25519:
            return SSH_KEYTYPE_ED25519;
        case PROSSH_KEY_ECDSA_P256:
            return SSH_KEYTYPE_ECDSA_P256;
        case PROSSH_KEY_ECDSA_P384:
            return SSH_KEYTYPE_ECDSA_P384;
        case PROSSH_KEY_ECDSA_P521:
            return SSH_KEYTYPE_ECDSA_P521;
        case PROSSH_KEY_DSA:
            return SSH_KEYTYPE_DSS;
        default:
            return SSH_KEYTYPE_UNKNOWN;
    }
}

static enum ssh_file_format_e prossh_map_private_key_format(ProSSHPrivateKeyFormat format) {
    switch (format) {
        case PROSSH_PRIVATE_KEY_PEM:
        case PROSSH_PRIVATE_KEY_PKCS8:
            return SSH_FILE_FORMAT_PEM;
        case PROSSH_PRIVATE_KEY_OPENSSH:
        default:
            return SSH_FILE_FORMAT_OPENSSH;
    }
}

static uint32_t prossh_read_u32_be(const unsigned char *data) {
    return ((uint32_t)data[0] << 24) |
           ((uint32_t)data[1] << 16) |
           ((uint32_t)data[2] << 8) |
           (uint32_t)data[3];
}

static char *prossh_dup_range(const char *start, const char *end) {
    if (start == NULL || end == NULL || end < start) {
        return NULL;
    }

    size_t length = (size_t)(end - start);
    char *result = (char *)malloc(length + 1);
    if (result == NULL) {
        return NULL;
    }

    if (length > 0) {
        memcpy(result, start, length);
    }
    result[length] = '\0';
    return result;
}

static char *prossh_trimmed_copy(const char *text) {
    if (text == NULL) {
        return NULL;
    }

    const char *start = text;
    while (*start != '\0' && (*start == ' ' || *start == '\t' || *start == '\r' || *start == '\n')) {
        start++;
    }

    const char *end = text + strlen(text);
    while (end > start && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) {
        end--;
    }

    return prossh_dup_range(start, end);
}

static int prossh_parse_public_key_tokens(
    const char *text,
    char **type_token,
    char **base64_token
) {
    if (type_token == NULL || base64_token == NULL) {
        return -1;
    }

    *type_token = NULL;
    *base64_token = NULL;

    char *trimmed = prossh_trimmed_copy(text);
    if (trimmed == NULL || trimmed[0] == '\0') {
        prossh_secure_free_cstring(trimmed);
        return -1;
    }

    const char *cursor = trimmed;
    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }

    const char *type_start = cursor;
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t' && *cursor != '\r' && *cursor != '\n') {
        cursor++;
    }
    const char *type_end = cursor;

    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }
    const char *base64_start = cursor;
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t' && *cursor != '\r' && *cursor != '\n') {
        cursor++;
    }
    const char *base64_end = cursor;

    char *parsed_type_token = prossh_dup_range(type_start, type_end);
    char *parsed_base64_token = prossh_dup_range(base64_start, base64_end);
    prossh_secure_free_cstring(trimmed);
    if (parsed_type_token == NULL || parsed_base64_token == NULL) {
        free(parsed_type_token);
        free(parsed_base64_token);
        return -1;
    }
    if (parsed_type_token[0] == '\0' || parsed_base64_token[0] == '\0') {
        free(parsed_type_token);
        free(parsed_base64_token);
        return -1;
    }

    *type_token = parsed_type_token;
    *base64_token = parsed_base64_token;
    return 0;
}

static int prossh_parse_openssh_ciphername(
    const char *private_key_text,
    char *cipher_buffer,
    size_t cipher_buffer_len
) {
    if (private_key_text == NULL || cipher_buffer == NULL || cipher_buffer_len == 0) {
        return -1;
    }

    prossh_copy_string(cipher_buffer, cipher_buffer_len, "");

    const char *begin_marker = "-----BEGIN OPENSSH PRIVATE KEY-----";
    const char *end_marker = "-----END OPENSSH PRIVATE KEY-----";
    const char *begin = strstr(private_key_text, begin_marker);
    const char *end = strstr(private_key_text, end_marker);
    if (begin == NULL || end == NULL || end <= begin) {
        return -2;
    }

    begin += strlen(begin_marker);
    while (*begin != '\0' && (*begin == '\r' || *begin == '\n' || *begin == ' ' || *begin == '\t')) {
        begin++;
    }

    char *base64_clean = (char *)malloc((size_t)(end - begin) + 1);
    if (base64_clean == NULL) {
        return -3;
    }

    size_t base64_length = 0;
    const char *cursor = begin;
    while (cursor < end) {
        unsigned char c = (unsigned char)*cursor;
        if ((c >= 'A' && c <= 'Z') ||
            (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') ||
            c == '+' || c == '/' || c == '=') {
            base64_clean[base64_length++] = (char)c;
        }
        cursor++;
    }
    base64_clean[base64_length] = '\0';

    if (base64_length == 0) {
        free(base64_clean);
        return -4;
    }

    size_t decoded_capacity = (base64_length / 4) * 3 + 3;
    unsigned char *decoded = (unsigned char *)malloc(decoded_capacity);
    if (decoded == NULL) {
        free(base64_clean);
        return -5;
    }

    size_t padding = 0;
    if (base64_length >= 1 && base64_clean[base64_length - 1] == '=') {
        padding++;
    }
    if (base64_length >= 2 && base64_clean[base64_length - 2] == '=') {
        padding++;
    }

    int decoded_length = EVP_DecodeBlock(decoded, (const unsigned char *)base64_clean, (int)base64_length);
    free(base64_clean);
    if (decoded_length <= 0) {
        free(decoded);
        return -6;
    }
    decoded_length -= (int)padding;

    static const char auth_magic[] = "openssh-key-v1";
    const size_t auth_magic_length = sizeof(auth_magic);
    if ((size_t)decoded_length < auth_magic_length + 4 ||
        memcmp(decoded, auth_magic, auth_magic_length) != 0) {
        free(decoded);
        return -7;
    }

    size_t offset = auth_magic_length;
    if (offset + 4 > (size_t)decoded_length) {
        free(decoded);
        return -8;
    }

    uint32_t cipher_length = prossh_read_u32_be(decoded + offset);
    offset += 4;
    if (offset + cipher_length > (size_t)decoded_length || cipher_length == 0) {
        free(decoded);
        return -9;
    }

    size_t copy_length = cipher_length;
    if (copy_length >= cipher_buffer_len) {
        copy_length = cipher_buffer_len - 1;
    }
    memcpy(cipher_buffer, decoded + offset, copy_length);
    cipher_buffer[copy_length] = '\0';

    free(decoded);
    return 0;
}

static ProSSHPrivateKeyFormat prossh_detect_private_key_format(const char *private_key_text) {
    if (private_key_text == NULL) {
        return PROSSH_PRIVATE_KEY_OPENSSH;
    }

    if (strstr(private_key_text, "BEGIN OPENSSH PRIVATE KEY") != NULL) {
        return PROSSH_PRIVATE_KEY_OPENSSH;
    }

    if (strstr(private_key_text, "BEGIN PRIVATE KEY") != NULL ||
        strstr(private_key_text, "BEGIN ENCRYPTED PRIVATE KEY") != NULL) {
        return PROSSH_PRIVATE_KEY_PKCS8;
    }

    return PROSSH_PRIVATE_KEY_PEM;
}

static ProSSHPrivateKeyCipher prossh_detect_private_key_cipher(
    ProSSHPrivateKeyFormat format,
    const char *private_key_text,
    bool *is_passphrase_protected
) {
    if (is_passphrase_protected != NULL) {
        *is_passphrase_protected = false;
    }

    if (private_key_text == NULL) {
        return PROSSH_PRIVATE_KEY_CIPHER_NONE;
    }

    if (format == PROSSH_PRIVATE_KEY_OPENSSH) {
        char cipher[64] = {0};
        if (prossh_parse_openssh_ciphername(private_key_text, cipher, sizeof(cipher)) == 0) {
            if (strcmp(cipher, "none") != 0) {
                if (is_passphrase_protected != NULL) {
                    *is_passphrase_protected = true;
                }
                if (strcmp(cipher, "aes256-ctr") == 0) {
                    return PROSSH_PRIVATE_KEY_CIPHER_AES256CTR;
                }
                if (strcmp(cipher, "chacha20-poly1305@openssh.com") == 0) {
                    return PROSSH_PRIVATE_KEY_CIPHER_CHACHA20_POLY1305;
                }
            }
            return PROSSH_PRIVATE_KEY_CIPHER_NONE;
        }
    }

    if (strstr(private_key_text, "BEGIN ENCRYPTED PRIVATE KEY") != NULL ||
        strstr(private_key_text, "Proc-Type: 4,ENCRYPTED") != NULL ||
        strstr(private_key_text, "DEK-Info:") != NULL) {
        if (is_passphrase_protected != NULL) {
            *is_passphrase_protected = true;
        }

        if (strstr(private_key_text, "AES-256-CTR") != NULL) {
            return PROSSH_PRIVATE_KEY_CIPHER_AES256CTR;
        }
        if (strstr(private_key_text, "ChaCha20") != NULL) {
            return PROSSH_PRIVATE_KEY_CIPHER_CHACHA20_POLY1305;
        }
    }

    return PROSSH_PRIVATE_KEY_CIPHER_NONE;
}

static int prossh_map_imported_key_type(
    ssh_key key,
    char *key_type_buffer,
    size_t key_type_buffer_len,
    int *bit_length
) {
    if (key == NULL || key_type_buffer == NULL || key_type_buffer_len == 0) {
        return -1;
    }

    enum ssh_keytypes_e key_type = ssh_key_type(key);
    int detected_bits = ssh_key_size(key);
    if (detected_bits <= 0) {
        switch (key_type) {
            case SSH_KEYTYPE_ED25519:
                detected_bits = 256;
                break;
            case SSH_KEYTYPE_ECDSA_P256:
                detected_bits = 256;
                break;
            case SSH_KEYTYPE_ECDSA_P384:
                detected_bits = 384;
                break;
            case SSH_KEYTYPE_ECDSA_P521:
                detected_bits = 521;
                break;
            case SSH_KEYTYPE_DSS:
                detected_bits = 1024;
                break;
            case SSH_KEYTYPE_RSA:
            default:
                detected_bits = -1;
                break;
        }
    }

    if (bit_length != NULL) {
        *bit_length = detected_bits;
    }

    switch (key_type) {
        case SSH_KEYTYPE_RSA:
            prossh_copy_string(key_type_buffer, key_type_buffer_len, "rsa");
            return 0;
        case SSH_KEYTYPE_ED25519:
            prossh_copy_string(key_type_buffer, key_type_buffer_len, "ed25519");
            return 0;
        case SSH_KEYTYPE_ECDSA_P256:
        case SSH_KEYTYPE_ECDSA_P384:
        case SSH_KEYTYPE_ECDSA_P521:
            prossh_copy_string(key_type_buffer, key_type_buffer_len, "ecdsa");
            return 0;
        case SSH_KEYTYPE_DSS:
            prossh_copy_string(key_type_buffer, key_type_buffer_len, "dsa");
            return 0;
        default:
            prossh_copy_string(key_type_buffer, key_type_buffer_len, "unknown");
            return -2;
    }
}

static int prossh_export_authorized_public_key(
    ssh_key public_key,
    const char *comment,
    char *public_key_buffer,
    size_t public_key_buffer_len
) {
    if (public_key == NULL || public_key_buffer == NULL || public_key_buffer_len == 0) {
        return -1;
    }

    char *public_key_base64 = NULL;
    if (ssh_pki_export_pubkey_base64(public_key, &public_key_base64) != SSH_OK || public_key_base64 == NULL) {
        return -2;
    }

    const char *public_key_type = ssh_key_type_to_char(ssh_key_type(public_key));
    if (public_key_type == NULL || public_key_type[0] == '\0') {
        public_key_type = "ssh-unknown";
    }

    const char *safe_comment = comment != NULL ? comment : "";
    int written = snprintf(
        public_key_buffer,
        public_key_buffer_len,
        safe_comment[0] == '\0' ? "%s %s" : "%s %s %s",
        public_key_type,
        public_key_base64,
        safe_comment
    );

    ssh_string_free_char(public_key_base64);
    if (written < 0 || (size_t)written >= public_key_buffer_len) {
        return -3;
    }

    return 0;
}

static void prossh_fill_key_fingerprints(
    ssh_key key,
    char *sha256_fingerprint_buffer,
    size_t sha256_fingerprint_buffer_len,
    char *md5_fingerprint_buffer,
    size_t md5_fingerprint_buffer_len
) {
    prossh_copy_string(sha256_fingerprint_buffer, sha256_fingerprint_buffer_len, "");
    prossh_copy_string(md5_fingerprint_buffer, md5_fingerprint_buffer_len, "");

    if (key == NULL) {
        return;
    }

    unsigned char *sha256_hash = NULL;
    size_t sha256_hash_len = 0;
    if (ssh_get_publickey_hash(key, SSH_PUBLICKEY_HASH_SHA256, &sha256_hash, &sha256_hash_len) == SSH_OK &&
        sha256_hash != NULL && sha256_hash_len > 0) {
        char *sha256_fingerprint = ssh_get_fingerprint_hash(
            SSH_PUBLICKEY_HASH_SHA256,
            sha256_hash,
            sha256_hash_len
        );
        if (sha256_fingerprint != NULL) {
            prossh_copy_string(
                sha256_fingerprint_buffer,
                sha256_fingerprint_buffer_len,
                sha256_fingerprint
            );
            ssh_string_free_char(sha256_fingerprint);
        }
        ssh_clean_pubkey_hash(&sha256_hash);
    }

    unsigned char *md5_hash = NULL;
    size_t md5_hash_len = 0;
    if (ssh_get_publickey_hash(key, SSH_PUBLICKEY_HASH_MD5, &md5_hash, &md5_hash_len) == SSH_OK &&
        md5_hash != NULL && md5_hash_len > 0) {
        char *md5_fingerprint = ssh_get_fingerprint_hash(
            SSH_PUBLICKEY_HASH_MD5,
            md5_hash,
            md5_hash_len
        );
        if (md5_fingerprint != NULL) {
            prossh_copy_string(
                md5_fingerprint_buffer,
                md5_fingerprint_buffer_len,
                md5_fingerprint
            );
            ssh_string_free_char(md5_fingerprint);
        }
        ssh_clean_pubkey_hash(&md5_hash);
    }
}

typedef struct ProSSHOpenSSHCipherConfig {
    const char *name;
    size_t block_size;
    size_t key_length;
    size_t iv_length;
    size_t auth_length;
} ProSSHOpenSSHCipherConfig;

static const ProSSHOpenSSHCipherConfig PROSSH_OPENSSH_CIPHER_NONE = {
    .name = "none",
    .block_size = 8,
    .key_length = 0,
    .iv_length = 0,
    .auth_length = 0
};

static const ProSSHOpenSSHCipherConfig PROSSH_OPENSSH_CIPHER_AES256CTR = {
    .name = "aes256-ctr",
    .block_size = 16,
    .key_length = 32,
    .iv_length = 16,
    .auth_length = 0
};

static const ProSSHOpenSSHCipherConfig PROSSH_OPENSSH_CIPHER_CHACHA20 = {
    .name = "chacha20-poly1305@openssh.com",
    .block_size = 8,
    .key_length = 64,
    .iv_length = 0,
    .auth_length = 16
};

static int prossh_buffer_add_u32(ssh_buffer buffer, uint32_t value) {
    unsigned char data[4];
    data[0] = (unsigned char)((value >> 24) & 0xff);
    data[1] = (unsigned char)((value >> 16) & 0xff);
    data[2] = (unsigned char)((value >> 8) & 0xff);
    data[3] = (unsigned char)(value & 0xff);
    return ssh_buffer_add_data(buffer, data, sizeof(data)) == SSH_OK ? 0 : -1;
}

static int prossh_buffer_add_string(ssh_buffer buffer, const void *data, size_t len) {
    if (prossh_buffer_add_u32(buffer, (uint32_t)len) != 0) {
        return -1;
    }

    if (len == 0) {
        return 0;
    }

    return ssh_buffer_add_data(buffer, data, (uint32_t)len) == SSH_OK ? 0 : -1;
}

static int prossh_base64_encode(
    const unsigned char *input,
    size_t input_len,
    char **output,
    size_t *output_len
) {
    if (input == NULL || output == NULL || output_len == NULL) {
        return -1;
    }

    *output = NULL;
    *output_len = 0;

    const size_t encoded_length = 4 * ((input_len + 2) / 3);
    char *encoded = (char *)malloc(encoded_length + 1);
    if (encoded == NULL) {
        return -2;
    }

    int actual = EVP_EncodeBlock((unsigned char *)encoded, input, (int)input_len);
    if (actual < 0) {
        free(encoded);
        return -3;
    }

    encoded[actual] = '\0';
    *output = encoded;
    *output_len = (size_t)actual;
    return 0;
}

static int prossh_poly1305_tag(
    const unsigned char *key,
    size_t key_len,
    const unsigned char *data,
    size_t data_len,
    unsigned char tag[16]
) {
    EVP_MAC *mac = EVP_MAC_fetch(NULL, "POLY1305", NULL);
    if (mac == NULL) {
        return -1;
    }

    EVP_MAC_CTX *context = EVP_MAC_CTX_new(mac);
    EVP_MAC_free(mac);
    if (context == NULL) {
        return -2;
    }

    size_t tag_len = 0;
    int ok = EVP_MAC_init(context, key, key_len, NULL) == 1 &&
             EVP_MAC_update(context, data, data_len) == 1 &&
             EVP_MAC_final(context, tag, &tag_len, 16) == 1 &&
             tag_len == 16;

    EVP_MAC_CTX_free(context);
    return ok ? 0 : -3;
}

static int prossh_encrypt_aes256_ctr(
    const unsigned char *plaintext,
    size_t plaintext_len,
    const unsigned char *key,
    const unsigned char *iv,
    unsigned char **encrypted_output,
    size_t *encrypted_output_len
) {
    if (plaintext == NULL || key == NULL || iv == NULL || encrypted_output == NULL || encrypted_output_len == NULL) {
        return -1;
    }

    *encrypted_output = NULL;
    *encrypted_output_len = 0;

    unsigned char *encrypted = (unsigned char *)malloc(plaintext_len + 1);
    if (encrypted == NULL) {
        return -2;
    }

    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (context == NULL) {
        free(encrypted);
        return -3;
    }

    int written = 0;
    int final_written = 0;
    int ok = EVP_EncryptInit_ex(context, EVP_aes_256_ctr(), NULL, key, iv) == 1 &&
             EVP_CIPHER_CTX_set_padding(context, 0) == 1 &&
             EVP_EncryptUpdate(context, encrypted, &written, plaintext, (int)plaintext_len) == 1 &&
             EVP_EncryptFinal_ex(context, encrypted + written, &final_written) == 1;

    EVP_CIPHER_CTX_free(context);
    if (!ok) {
        free(encrypted);
        return -4;
    }

    *encrypted_output = encrypted;
    *encrypted_output_len = (size_t)(written + final_written);
    return 0;
}

static int prossh_encrypt_chacha20_poly1305_openssh(
    const unsigned char *plaintext,
    size_t plaintext_len,
    const unsigned char *key_material,
    unsigned char **encrypted_output,
    size_t *encrypted_output_len
) {
    if (plaintext == NULL || key_material == NULL || encrypted_output == NULL || encrypted_output_len == NULL) {
        return -1;
    }

    *encrypted_output = NULL;
    *encrypted_output_len = 0;

    unsigned char *encrypted = (unsigned char *)malloc(plaintext_len + 16);
    if (encrypted == NULL) {
        return -2;
    }

    EVP_CIPHER_CTX *context = EVP_CIPHER_CTX_new();
    if (context == NULL) {
        free(encrypted);
        return -3;
    }

    unsigned char seq_buffer[16] = {0};
    unsigned char poly_key[32] = {0};
    unsigned char zeros[32] = {0};
    unsigned char tag[16] = {0};

    int temp_written = 0;
    int encrypted_written = 0;
    int final_written = 0;
    int ok = EVP_EncryptInit_ex(context, EVP_chacha20(), NULL, key_material, seq_buffer) == 1 &&
             EVP_CIPHER_CTX_set_padding(context, 0) == 1 &&
             EVP_EncryptUpdate(context, poly_key, &temp_written, zeros, (int)sizeof(zeros)) == 1;

    if (ok) {
        seq_buffer[0] = 1;
        ok = EVP_EncryptInit_ex(context, EVP_chacha20(), NULL, key_material, seq_buffer) == 1 &&
             EVP_CIPHER_CTX_set_padding(context, 0) == 1 &&
             EVP_EncryptUpdate(context, encrypted, &encrypted_written, plaintext, (int)plaintext_len) == 1 &&
             EVP_EncryptFinal_ex(context, encrypted + encrypted_written, &final_written) == 1;
    }

    EVP_CIPHER_CTX_free(context);
    if (!ok) {
        free(encrypted);
        return -4;
    }

    const size_t ciphertext_len = (size_t)(encrypted_written + final_written);
    if (prossh_poly1305_tag(poly_key, sizeof(poly_key), encrypted, ciphertext_len, tag) != 0) {
        free(encrypted);
        return -5;
    }

    memcpy(encrypted + ciphertext_len, tag, sizeof(tag));
    *encrypted_output = encrypted;
    *encrypted_output_len = ciphertext_len + sizeof(tag);
    return 0;
}

static int prossh_export_openssh_private_key(
    ssh_key private_key,
    const char *passphrase,
    ProSSHPrivateKeyCipher requested_cipher,
    const char *comment,
    char **private_key_output,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (private_key == NULL || private_key_output == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid OpenSSH private key export parameters.");
        return -1;
    }

    *private_key_output = NULL;

    const bool encrypt_private_key = passphrase != NULL && passphrase[0] != '\0';
    const ProSSHOpenSSHCipherConfig *cipher = &PROSSH_OPENSSH_CIPHER_NONE;
    if (encrypt_private_key) {
        switch (requested_cipher) {
            case PROSSH_PRIVATE_KEY_CIPHER_CHACHA20_POLY1305:
                cipher = &PROSSH_OPENSSH_CIPHER_CHACHA20;
                break;
            case PROSSH_PRIVATE_KEY_CIPHER_AES256CTR:
            case PROSSH_PRIVATE_KEY_CIPHER_NONE:
            default:
                cipher = &PROSSH_OPENSSH_CIPHER_AES256CTR;
                break;
        }
    }

    ssh_string public_key_blob = NULL;
    if (ssh_pki_export_pubkey_blob(private_key, &public_key_blob) != SSH_OK || public_key_blob == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to export OpenSSH public key blob.");
        return -2;
    }

    ssh_string private_key_blob = NULL;
    if (ssh_pki_export_privkey_blob(private_key, &private_key_blob) != SSH_OK || private_key_blob == NULL) {
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to export OpenSSH private key blob.");
        return -3;
    }

    ssh_buffer private_section = ssh_buffer_new();
    if (private_section == NULL) {
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate OpenSSH private section buffer.");
        return -4;
    }

    uint32_t checkint = 0;
    if (!ssh_get_random(&checkint, (int)sizeof(checkint), 0)) {
        SSH_BUFFER_FREE(private_section);
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to generate OpenSSH checkint.");
        return -5;
    }

    const char *safe_comment = comment != NULL ? comment : "";
    if (prossh_buffer_add_u32(private_section, checkint) != 0 ||
        prossh_buffer_add_u32(private_section, checkint) != 0 ||
        prossh_buffer_add_string(
            private_section,
            ssh_string_data(private_key_blob),
            ssh_string_len(private_key_blob)
        ) != 0 ||
        prossh_buffer_add_string(private_section, safe_comment, strlen(safe_comment)) != 0) {
        SSH_BUFFER_FREE(private_section);
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to assemble OpenSSH private section.");
        return -6;
    }

    unsigned char padding_byte = 1;
    while ((ssh_buffer_get_len(private_section) % cipher->block_size) != 0) {
        if (ssh_buffer_add_data(private_section, &padding_byte, 1) != SSH_OK) {
            SSH_BUFFER_FREE(private_section);
            ssh_string_free(private_key_blob);
            ssh_string_free(public_key_blob);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to append OpenSSH private key padding.");
            return -7;
        }
        padding_byte = (unsigned char)((padding_byte + 1) & 0xff);
    }

    unsigned char salt[16] = {0};
    const uint32_t bcrypt_rounds = 16;
    unsigned char *key_material = NULL;
    unsigned char *encrypted_private = NULL;
    size_t encrypted_private_len = 0;
    size_t clear_private_len = ssh_buffer_get_len(private_section);

    if (encrypt_private_key) {
        const size_t key_material_len = cipher->key_length + cipher->iv_length;
        key_material = (unsigned char *)calloc(1, key_material_len);
        if (key_material == NULL) {
            SSH_BUFFER_FREE(private_section);
            ssh_string_free(private_key_blob);
            ssh_string_free(public_key_blob);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate OpenSSH key-derivation buffer.");
            return -8;
        }

        if (!ssh_get_random(salt, (int)sizeof(salt), 0)) {
            free(key_material);
            SSH_BUFFER_FREE(private_section);
            ssh_string_free(private_key_blob);
            ssh_string_free(public_key_blob);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to generate OpenSSH KDF salt.");
            return -9;
        }

        if (bcrypt_pbkdf(
                passphrase,
                strlen(passphrase),
                salt,
                sizeof(salt),
                key_material,
                key_material_len,
                bcrypt_rounds
            ) < 0) {
            free(key_material);
            SSH_BUFFER_FREE(private_section);
            ssh_string_free(private_key_blob);
            ssh_string_free(public_key_blob);
            prossh_copy_string(error_buffer, error_buffer_len, "OpenSSH bcrypt key derivation failed.");
            return -10;
        }

        const unsigned char *plain_private = (const unsigned char *)ssh_buffer_get(private_section);
        int encrypt_result = 0;
        if (strcmp(cipher->name, "aes256-ctr") == 0) {
            encrypt_result = prossh_encrypt_aes256_ctr(
                plain_private,
                clear_private_len,
                key_material,
                key_material + cipher->key_length,
                &encrypted_private,
                &encrypted_private_len
            );
        } else {
            encrypt_result = prossh_encrypt_chacha20_poly1305_openssh(
                plain_private,
                clear_private_len,
                key_material,
                &encrypted_private,
                &encrypted_private_len
            );
        }

        if (encrypt_result != 0 || encrypted_private == NULL) {
            free(key_material);
            SSH_BUFFER_FREE(private_section);
            ssh_string_free(private_key_blob);
            ssh_string_free(public_key_blob);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to encrypt OpenSSH private section.");
            return -11;
        }
    } else {
        encrypted_private = (unsigned char *)malloc(clear_private_len);
        if (encrypted_private == NULL) {
            SSH_BUFFER_FREE(private_section);
            ssh_string_free(private_key_blob);
            ssh_string_free(public_key_blob);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate OpenSSH private output.");
            return -12;
        }

        memcpy(encrypted_private, ssh_buffer_get(private_section), clear_private_len);
        encrypted_private_len = clear_private_len;
    }

    ssh_buffer encoded = ssh_buffer_new();
    if (encoded == NULL) {
        free(encrypted_private);
        free(key_material);
        SSH_BUFFER_FREE(private_section);
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate OpenSSH output buffer.");
        return -13;
    }

    static const unsigned char auth_magic[] = "openssh-key-v1";
    const char *kdf_name = encrypt_private_key ? "bcrypt" : "none";

    ssh_buffer kdf_options = ssh_buffer_new();
    if (kdf_options == NULL) {
        SSH_BUFFER_FREE(encoded);
        free(encrypted_private);
        free(key_material);
        SSH_BUFFER_FREE(private_section);
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate OpenSSH KDF options buffer.");
        return -14;
    }

    if (encrypt_private_key) {
        if (prossh_buffer_add_string(kdf_options, salt, sizeof(salt)) != 0 ||
            prossh_buffer_add_u32(kdf_options, bcrypt_rounds) != 0) {
            SSH_BUFFER_FREE(kdf_options);
            SSH_BUFFER_FREE(encoded);
            free(encrypted_private);
            free(key_material);
            SSH_BUFFER_FREE(private_section);
            ssh_string_free(private_key_blob);
            ssh_string_free(public_key_blob);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to encode OpenSSH KDF options.");
            return -15;
        }
    }

    int encode_error = 0;
    if (ssh_buffer_add_data(encoded, auth_magic, sizeof(auth_magic)) != SSH_OK ||
        prossh_buffer_add_string(encoded, cipher->name, strlen(cipher->name)) != 0 ||
        prossh_buffer_add_string(encoded, kdf_name, strlen(kdf_name)) != 0 ||
        prossh_buffer_add_string(encoded, ssh_buffer_get(kdf_options), ssh_buffer_get_len(kdf_options)) != 0 ||
        prossh_buffer_add_u32(encoded, 1) != 0 ||
        prossh_buffer_add_string(encoded, ssh_string_data(public_key_blob), ssh_string_len(public_key_blob)) != 0 ||
        prossh_buffer_add_u32(encoded, (uint32_t)clear_private_len) != 0 ||
        ssh_buffer_add_data(encoded, encrypted_private, (uint32_t)encrypted_private_len) != SSH_OK) {
        encode_error = 1;
    }

    if (encode_error) {
        SSH_BUFFER_FREE(kdf_options);
        SSH_BUFFER_FREE(encoded);
        free(encrypted_private);
        free(key_material);
        SSH_BUFFER_FREE(private_section);
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to encode OpenSSH private key output.");
        return -16;
    }

    char *base64_data = NULL;
    size_t base64_len = 0;
    if (prossh_base64_encode(
            (const unsigned char *)ssh_buffer_get(encoded),
            ssh_buffer_get_len(encoded),
            &base64_data,
            &base64_len
        ) != 0 || base64_data == NULL) {
        SSH_BUFFER_FREE(kdf_options);
        SSH_BUFFER_FREE(encoded);
        free(encrypted_private);
        free(key_material);
        SSH_BUFFER_FREE(private_section);
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to base64 encode OpenSSH private key.");
        return -17;
    }

    const size_t line_width = 70;
    const size_t line_count = base64_len == 0 ? 1 : ((base64_len + line_width - 1) / line_width);
    const size_t output_capacity = strlen("-----BEGIN OPENSSH PRIVATE KEY-----\n") +
                                   strlen("-----END OPENSSH PRIVATE KEY-----\n") +
                                   base64_len + line_count + 1;

    char *formatted_output = (char *)malloc(output_capacity);
    if (formatted_output == NULL) {
        free(base64_data);
        SSH_BUFFER_FREE(kdf_options);
        SSH_BUFFER_FREE(encoded);
        free(encrypted_private);
        free(key_material);
        SSH_BUFFER_FREE(private_section);
        ssh_string_free(private_key_blob);
        ssh_string_free(public_key_blob);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate OpenSSH final output buffer.");
        return -18;
    }

    size_t cursor = 0;
    cursor += (size_t)snprintf(
        formatted_output + cursor,
        output_capacity - cursor,
        "-----BEGIN OPENSSH PRIVATE KEY-----\n"
    );

    if (base64_len == 0) {
        formatted_output[cursor++] = '\n';
    } else {
        size_t offset = 0;
        while (offset < base64_len) {
            size_t chunk = base64_len - offset;
            if (chunk > line_width) {
                chunk = line_width;
            }
            memcpy(formatted_output + cursor, base64_data + offset, chunk);
            cursor += chunk;
            formatted_output[cursor++] = '\n';
            offset += chunk;
        }
    }

    cursor += (size_t)snprintf(
        formatted_output + cursor,
        output_capacity - cursor,
        "-----END OPENSSH PRIVATE KEY-----\n"
    );

    formatted_output[cursor] = '\0';
    *private_key_output = formatted_output;

    free(base64_data);
    SSH_BUFFER_FREE(kdf_options);
    SSH_BUFFER_FREE(encoded);
    free(encrypted_private);
    free(key_material);
    SSH_BUFFER_FREE(private_section);
    ssh_string_free(private_key_blob);
    ssh_string_free(public_key_blob);
    return 0;
}

static int prossh_convert_pem_to_pkcs8(
    const char *pem_input,
    char **pkcs8_output,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (pem_input == NULL || pkcs8_output == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid PKCS#8 conversion input.");
        return -1;
    }

    *pkcs8_output = NULL;

    BIO *input = BIO_new_mem_buf((const void *)pem_input, -1);
    if (input == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate BIO for PKCS#8 conversion.");
        return -2;
    }

    EVP_PKEY *private_key = PEM_read_bio_PrivateKey(input, NULL, NULL, NULL);
    if (private_key == NULL) {
        BIO_free(input);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to parse PEM private key for PKCS#8 conversion.");
        return -3;
    }

    BIO *output = BIO_new(BIO_s_mem());
    if (output == NULL) {
        EVP_PKEY_free(private_key);
        BIO_free(input);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate output BIO for PKCS#8 conversion.");
        return -4;
    }

    if (PEM_write_bio_PKCS8PrivateKey(output, private_key, NULL, NULL, 0, NULL, NULL) != 1) {
        BIO_free(output);
        EVP_PKEY_free(private_key);
        BIO_free(input);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to encode PKCS#8 private key.");
        return -5;
    }

    BUF_MEM *memory = NULL;
    BIO_get_mem_ptr(output, &memory);
    if (memory == NULL || memory->data == NULL || memory->length == 0) {
        BIO_free(output);
        EVP_PKEY_free(private_key);
        BIO_free(input);
        prossh_copy_string(error_buffer, error_buffer_len, "PKCS#8 conversion produced empty output.");
        return -6;
    }

    char *allocated = (char *)malloc(memory->length + 1);
    if (allocated == NULL) {
        BIO_free(output);
        EVP_PKEY_free(private_key);
        BIO_free(input);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate PKCS#8 output buffer.");
        return -7;
    }

    memcpy(allocated, memory->data, memory->length);
    allocated[memory->length] = '\0';
    *pkcs8_output = allocated;

    BIO_free(output);
    EVP_PKEY_free(private_key);
    BIO_free(input);
    return 0;
}

ProSSHLibSSHHandle *prossh_libssh_create(void) {
    ProSSHLibSSHHandle *handle = (ProSSHLibSSHHandle *)calloc(1, sizeof(ProSSHLibSSHHandle));
    return handle;
}

int prossh_libssh_send_keepalive(ProSSHLibSSHHandle *handle) {
    if (handle == NULL || handle->session == NULL) {
        return -1;
    }

    if (ssh_is_connected(handle->session) == 0) {
        return -2;
    }

    return ssh_send_ignore(handle->session, "") == SSH_OK ? 0 : -2;
}

void prossh_libssh_channel_close(ProSSHLibSSHHandle *handle) {
    if (handle == NULL || handle->channel == NULL) {
        return;
    }

    ssh_channel_close(handle->channel);
    ssh_channel_free(handle->channel);
    handle->channel = NULL;
}

void prossh_libssh_disconnect(ProSSHLibSSHHandle *handle) {
    if (handle == NULL) {
        return;
    }

    prossh_libssh_channel_close(handle);

    if (handle->session != NULL) {
        ssh_disconnect(handle->session);
        ssh_free(handle->session);
        handle->session = NULL;
    }
}

void prossh_libssh_destroy(ProSSHLibSSHHandle *handle) {
    if (handle == NULL) {
        return;
    }

    prossh_libssh_disconnect(handle);
    free(handle);
}

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
) {
    if (handle == NULL || hostname == NULL || username == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid connection parameters.");
        return -1;
    }

    prossh_libssh_disconnect(handle);

    handle->session = ssh_new();
    if (handle->session == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate libssh session.");
        return -1;
    }

    if (prossh_apply_options(
            handle,
            hostname,
            port,
            username,
            kex,
            ciphers,
            hostkeys,
            macs,
            timeout_seconds,
            error_buffer,
            error_buffer_len
        ) != 0) {
        return -1;
    }

    if (ssh_connect(handle->session) != SSH_OK) {
        prossh_set_error(handle, "SSH connection failed", error_buffer, error_buffer_len);
        return -2;
    }

    return 0;
}

static int prossh_get_session_fingerprint(
    ssh_session session,
    char *fingerprint_buffer,
    size_t fingerprint_buffer_len
) {
    ssh_key server_key = NULL;
    if (ssh_get_server_publickey(session, &server_key) != SSH_OK || server_key == NULL) {
        prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, "unknown");
        return -1;
    }

    unsigned char *hash = NULL;
    size_t hash_len = 0;
    if (ssh_get_publickey_hash(server_key, SSH_PUBLICKEY_HASH_SHA256, &hash, &hash_len) == SSH_OK &&
        hash != NULL && hash_len > 0) {
        char *hex = ssh_get_hexa(hash, hash_len);
        if (hex != NULL) {
            prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, hex);
            ssh_string_free_char(hex);
        } else {
            prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, "unknown");
        }
        ssh_clean_pubkey_hash(&hash);
    } else {
        prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, "unknown");
    }

    ssh_key_free(server_key);
    return 0;
}

static int prossh_jump_before_connection(ssh_session session, void *userdata) {
    ProSSHJumpHostConfig *config = (ProSSHJumpHostConfig *)userdata;
    if (config == NULL) {
        return -1;
    }

    int strict_host_key_check = 0;
    ssh_options_set(session, SSH_OPTIONS_STRICTHOSTKEYCHECK, &strict_host_key_check);

    if (config->kex != NULL && config->kex[0] != '\0') {
        if (ssh_options_set(session, SSH_OPTIONS_KEY_EXCHANGE, config->kex) != SSH_OK) {
            prossh_copy_string(config->callback_error, sizeof(config->callback_error),
                             "Jump host: failed to set key-exchange algorithms");
            return -1;
        }
    }

    if (config->ciphers != NULL && config->ciphers[0] != '\0') {
        if (ssh_options_set(session, SSH_OPTIONS_CIPHERS_C_S, config->ciphers) != SSH_OK ||
            ssh_options_set(session, SSH_OPTIONS_CIPHERS_S_C, config->ciphers) != SSH_OK) {
            prossh_copy_string(config->callback_error, sizeof(config->callback_error),
                             "Jump host: failed to set ciphers");
            return -1;
        }
    }

    if (config->hostkeys != NULL && config->hostkeys[0] != '\0') {
        if (ssh_options_set(session, SSH_OPTIONS_HOSTKEYS, config->hostkeys) != SSH_OK) {
            prossh_copy_string(config->callback_error, sizeof(config->callback_error),
                             "Jump host: failed to set host key algorithms");
            return -1;
        }
    }

    if (config->macs != NULL && config->macs[0] != '\0') {
        if (ssh_options_set(session, SSH_OPTIONS_HMAC_C_S, config->macs) != SSH_OK ||
            ssh_options_set(session, SSH_OPTIONS_HMAC_S_C, config->macs) != SSH_OK) {
            prossh_copy_string(config->callback_error, sizeof(config->callback_error),
                             "Jump host: failed to set MAC algorithms");
            return -1;
        }
    }

    if (config->timeout_seconds > 0) {
        long timeout = (long)config->timeout_seconds;
        ssh_options_set(session, SSH_OPTIONS_TIMEOUT, &timeout);
    }

    return 0;
}

static int prossh_jump_verify_knownhost(ssh_session session, void *userdata) {
    ProSSHJumpHostConfig *config = (ProSSHJumpHostConfig *)userdata;
    if (config == NULL) {
        return -1;
    }

    config->verify_result = prossh_get_session_fingerprint(
        session,
        config->actual_fingerprint,
        sizeof(config->actual_fingerprint)
    );

    if (config->verify_result != 0) {
        prossh_copy_string(config->callback_error, sizeof(config->callback_error),
                         "Jump host: unable to retrieve host key fingerprint");
        return -1;
    }

    if (config->expected_fingerprint == NULL || config->expected_fingerprint[0] == '\0') {
        prossh_copy_string(config->callback_error, sizeof(config->callback_error),
                         "Jump host: host key verification required (no known fingerprint)");
        config->verify_result = -2;
        return -1;
    }

    if (strcmp(config->actual_fingerprint, config->expected_fingerprint) != 0) {
        snprintf(config->callback_error, sizeof(config->callback_error),
                "Jump host: host key mismatch (expected %s, got %s)",
                config->expected_fingerprint, config->actual_fingerprint);
        config->verify_result = -3;
        return -1;
    }

    config->verify_result = 0;
    return 0;
}

static int prossh_jump_authenticate(ssh_session session, void *userdata) {
    ProSSHJumpHostConfig *config = (ProSSHJumpHostConfig *)userdata;
    if (config == NULL) {
        return -1;
    }

    struct ProSSHLibSSHHandle jump_handle;
    jump_handle.session = session;
    jump_handle.channel = NULL;

    char auth_error[512];
    memset(auth_error, 0, sizeof(auth_error));

    int result = prossh_authenticate(
        &jump_handle,
        config->auth_method,
        config->password,
        config->private_key,
        config->certificate,
        config->key_passphrase,
        auth_error,
        sizeof(auth_error)
    );

    config->auth_result = result;
    if (result != 0) {
        if (auth_error[0] != '\0') {
            snprintf(config->callback_error, sizeof(config->callback_error),
                    "Jump host authentication: %s", auth_error);
        } else {
            prossh_copy_string(config->callback_error, sizeof(config->callback_error),
                             "Jump host: authentication failed");
        }
        return -1;
    }

    return 0;
}

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
) {
    if (handle == NULL || hostname == NULL || username == NULL || jump_config == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid connection parameters.");
        return -1;
    }

    if (jump_config->jump_hostname == NULL || jump_config->jump_username == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid jump host parameters.");
        return -1;
    }

    prossh_libssh_disconnect(handle);

    handle->session = ssh_new();
    if (handle->session == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate libssh session.");
        return -1;
    }

    if (prossh_apply_options(
            handle, hostname, port, username,
            kex, ciphers, hostkeys, macs,
            timeout_seconds, error_buffer, error_buffer_len
        ) != 0) {
        return -1;
    }

    char proxy_jump_str[512];
    snprintf(proxy_jump_str, sizeof(proxy_jump_str), "%s@%s:%u",
            jump_config->jump_username,
            jump_config->jump_hostname,
            (unsigned int)jump_config->jump_port);

    if (ssh_options_set(handle->session, SSH_OPTIONS_PROXYJUMP, proxy_jump_str) != SSH_OK) {
        prossh_set_error(handle, "Failed to set ProxyJump option", error_buffer, error_buffer_len);
        return -1;
    }

    memset(jump_config->actual_fingerprint, 0, sizeof(jump_config->actual_fingerprint));
    memset(jump_config->callback_error, 0, sizeof(jump_config->callback_error));
    jump_config->verify_result = 0;
    jump_config->auth_result = 0;

    struct ssh_jump_callbacks_struct jump_cb;
    memset(&jump_cb, 0, sizeof(jump_cb));
    jump_cb.userdata = jump_config;
    jump_cb.before_connection = prossh_jump_before_connection;
    jump_cb.verify_knownhost = prossh_jump_verify_knownhost;
    jump_cb.authenticate = prossh_jump_authenticate;

    if (ssh_options_set(handle->session, SSH_OPTIONS_PROXYJUMP_CB_LIST_APPEND, &jump_cb) != SSH_OK) {
        prossh_set_error(handle, "Failed to set ProxyJump callbacks", error_buffer, error_buffer_len);
        return -1;
    }

    if (ssh_connect(handle->session) != SSH_OK) {
        if (jump_config->callback_error[0] != '\0') {
            prossh_copy_string(error_buffer, error_buffer_len, jump_config->callback_error);
        } else {
            prossh_set_error(handle, "SSH connection via jump host failed", error_buffer, error_buffer_len);
        }

        if (jump_config->verify_result == -2) {
            return -10;
        }
        if (jump_config->verify_result == -3) {
            return -11;
        }
        if (jump_config->auth_result != 0) {
            return -12;
        }

        return -2;
    }

    return 0;
}

int prossh_libssh_authenticate(
    ProSSHLibSSHHandle *handle,
    ProSSHAuthMethod auth_method,
    const char *password,
    const char *private_key,
    const char *certificate,
    const char *key_passphrase,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (handle == NULL || handle->session == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "SSH session is not connected.");
        return -1;
    }

    if (prossh_authenticate(
            handle,
            auth_method,
            password,
            private_key,
            certificate,
            key_passphrase,
            error_buffer,
            error_buffer_len
        ) != 0) {
        return -3;
    }

    return 0;
}

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
) {
    if (handle == NULL || handle->session == NULL) {
        return -1;
    }

    prossh_copy_string(kex_buffer, kex_buffer_len, ssh_get_kex_algo(handle->session));
    prossh_copy_string(cipher_buffer, cipher_buffer_len, ssh_get_cipher_in(handle->session));

    ssh_key server_key = NULL;
    if (ssh_get_server_publickey(handle->session, &server_key) == SSH_OK && server_key != NULL) {
        enum ssh_keytypes_e key_type = ssh_key_type(server_key);
        const char *key_name = ssh_key_type_to_char(key_type);
        prossh_copy_string(hostkey_buffer, hostkey_buffer_len, key_name);

        unsigned char *hash = NULL;
        size_t hash_len = 0;
        if (ssh_get_publickey_hash(server_key, SSH_PUBLICKEY_HASH_SHA256, &hash, &hash_len) == SSH_OK &&
            hash != NULL && hash_len > 0) {
            char *hex = ssh_get_hexa(hash, hash_len);
            if (hex != NULL) {
                prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, hex);
                ssh_string_free_char(hex);
            } else {
                prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, "unknown");
            }
            ssh_clean_pubkey_hash(&hash);
        } else {
            prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, "unknown");
        }

        ssh_key_free(server_key);
    } else {
        prossh_copy_string(hostkey_buffer, hostkey_buffer_len, "unknown");
        prossh_copy_string(fingerprint_buffer, fingerprint_buffer_len, "unknown");
    }

    return 0;
}

int prossh_libssh_open_shell(
    ProSSHLibSSHHandle *handle,
    int columns,
    int rows,
    const char *terminal_type,
    bool enable_agent_forwarding,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (handle == NULL || handle->session == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "SSH session is not connected.");
        return -1;
    }

    prossh_libssh_channel_close(handle);

    handle->channel = ssh_channel_new(handle->session);
    if (handle->channel == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to create SSH channel.");
        return -1;
    }

    if (ssh_channel_open_session(handle->channel) != SSH_OK) {
        prossh_set_error(handle, "Failed to open channel session.", error_buffer, error_buffer_len);
        prossh_libssh_channel_close(handle);
        return -2;
    }

    if (enable_agent_forwarding) {
        if (ssh_channel_request_auth_agent(handle->channel) != SSH_OK) {
            prossh_set_error(handle, "Failed to enable agent forwarding on channel.", error_buffer, error_buffer_len);
            prossh_libssh_channel_close(handle);
            return -5;
        }
    }

    const char *term = (terminal_type != NULL && terminal_type[0] != '\0') ? terminal_type : "xterm-256color";
    unsigned char pty_modes[128];
    size_t pty_modes_len = 0;

    // RFC 4254 PTY mode opcodes:
    // VINTR=1, VQUIT=2, VERASE=3, VKILL=4, VEOF=5, VSTART=8, VSTOP=9, VSUSP=10,
    // ISIG=50, ICANON=51, ECHO=53, ECHOE=54, ECHOK=55, ICRNL=36, OPOST=70, ONLCR=72.
    // Some servers zero out unspecified control chars when modes are explicitly sent.
    // Set the common control-byte defaults so Ctrl-C/Ctrl-Z/Ctrl-\ keep generating signals.
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 1, 3);   // VINTR  = Ctrl-C
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 2, 28);  // VQUIT  = Ctrl-\
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 3, 127); // VERASE = DEL
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 4, 21);  // VKILL  = Ctrl-U
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 5, 4);   // VEOF   = Ctrl-D
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 8, 17);  // VSTART = Ctrl-Q
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 9, 19);  // VSTOP  = Ctrl-S
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 10, 26); // VSUSP  = Ctrl-Z
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 50, 1); // ISIG
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 51, 1); // ICANON
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 53, 1); // ECHO
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 54, 1); // ECHOE
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 55, 1); // ECHOK
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 36, 1); // ICRNL
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 70, 1); // OPOST
    prossh_append_pty_mode(pty_modes, &pty_modes_len, sizeof(pty_modes), 72, 1); // ONLCR

    if (pty_modes_len < sizeof(pty_modes)) {
        pty_modes[pty_modes_len++] = 0; // TTY_OP_END
    }

    int pty_result = ssh_channel_request_pty_size_modes(
        handle->channel,
        term,
        columns,
        rows,
        (const unsigned char *)pty_modes,
        pty_modes_len
    );

    if (pty_result != SSH_OK) {
        // Fallback for servers that reject explicit PTY mode blobs.
        if (ssh_channel_request_pty_size(handle->channel, term, columns, rows) != SSH_OK) {
            prossh_set_error(handle, "Failed to request PTY.", error_buffer, error_buffer_len);
            prossh_libssh_channel_close(handle);
            return -3;
        }
    }

    if (ssh_channel_request_shell(handle->channel) != SSH_OK) {
        prossh_set_error(handle, "Failed to request shell.", error_buffer, error_buffer_len);
        prossh_libssh_channel_close(handle);
        return -4;
    }

    ssh_channel_set_blocking(handle->channel, 0);
    return 0;
}

int prossh_libssh_channel_resize_pty(
    ProSSHLibSSHHandle *handle,
    int columns,
    int rows,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (handle == NULL || handle->channel == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid handle or channel.");
        return -1;
    }

    if (ssh_channel_change_pty_size(handle->channel, columns, rows) != SSH_OK) {
        prossh_set_error(handle, "Failed to resize PTY.", error_buffer, error_buffer_len);
        return -2;
    }

    return 0;
}

int prossh_libssh_channel_write(
    ProSSHLibSSHHandle *handle,
    const char *input,
    size_t input_len,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (handle == NULL || handle->channel == NULL || input == NULL || input_len == 0) {
        return -1;
    }

    int written = ssh_channel_write(handle->channel, input, (uint32_t)input_len);
    if (written == SSH_ERROR) {
        prossh_set_error(handle, "Failed to write to shell channel.", error_buffer, error_buffer_len);
        return -2;
    }

    return 0;
}

int prossh_libssh_channel_read(
    ProSSHLibSSHHandle *handle,
    char *output_buffer,
    size_t output_buffer_len,
    int *bytes_read,
    bool *is_eof,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (bytes_read != NULL) {
        *bytes_read = 0;
    }
    if (is_eof != NULL) {
        *is_eof = false;
    }

    if (handle == NULL || handle->channel == NULL || output_buffer == NULL || output_buffer_len < 2) {
        return -1;
    }

    int total_read = 0;

    int stdout_read = ssh_channel_read_nonblocking(
        handle->channel,
        output_buffer,
        (uint32_t)(output_buffer_len - 1),
        0
    );

    if (stdout_read == SSH_ERROR) {
        prossh_set_error(handle, "Failed reading shell output.", error_buffer, error_buffer_len);
        return -2;
    }

    if (stdout_read > 0) {
        total_read += stdout_read;
    }

    int remaining = (int)(output_buffer_len - 1 - (size_t)total_read);
    if (remaining > 0) {
        int stderr_read = ssh_channel_read_nonblocking(
            handle->channel,
            output_buffer + total_read,
            (uint32_t)remaining,
            1
        );

        if (stderr_read == SSH_ERROR) {
            prossh_set_error(handle, "Failed reading shell stderr.", error_buffer, error_buffer_len);
            return -3;
        }

        if (stderr_read > 0) {
            total_read += stderr_read;
        }
    }

    output_buffer[total_read] = '\0';

    if (bytes_read != NULL) {
        *bytes_read = total_read;
    }

    if (is_eof != NULL) {
        *is_eof = ssh_channel_is_eof(handle->channel) != 0;
    }

    return 0;
}

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
) {
    prossh_copy_string(private_key_buffer, private_key_buffer_len, "");
    prossh_copy_string(public_key_buffer, public_key_buffer_len, "");
    prossh_copy_string(sha256_fingerprint_buffer, sha256_fingerprint_buffer_len, "");
    prossh_copy_string(md5_fingerprint_buffer, md5_fingerprint_buffer_len, "");

    const bool has_passphrase = passphrase != NULL && passphrase[0] != '\0';
    const bool private_key_uses_malloc = has_passphrase && private_key_format == PROSSH_PRIVATE_KEY_OPENSSH;

    enum ssh_keytypes_e key_type = prossh_map_key_algorithm(algorithm);
    if (key_type == SSH_KEYTYPE_UNKNOWN) {
        prossh_copy_string(error_buffer, error_buffer_len, "Unsupported key generation algorithm.");
        return -1;
    }

    ssh_pki_ctx pki_context = ssh_pki_ctx_new();
    if (pki_context == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate PKI context.");
        return -2;
    }

    if (algorithm == PROSSH_KEY_RSA && parameter > 0) {
        if (ssh_pki_ctx_options_set(pki_context, SSH_PKI_OPTION_RSA_KEY_SIZE, &parameter) != SSH_OK) {
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to set RSA key size.");
            ssh_pki_ctx_free(pki_context);
            return -3;
        }
    }

    ssh_key private_key = NULL;
    if (ssh_pki_generate_key(key_type, pki_context, &private_key) != SSH_OK || private_key == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Key generation failed.");
        ssh_pki_ctx_free(pki_context);
        return -4;
    }

    ssh_key public_key = NULL;
    if (ssh_pki_export_privkey_to_pubkey(private_key, &public_key) != SSH_OK || public_key == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to derive public key.");
        ssh_key_free(private_key);
        ssh_pki_ctx_free(pki_context);
        return -5;
    }

    char *private_key_output = NULL;
    if (has_passphrase && private_key_format == PROSSH_PRIVATE_KEY_OPENSSH) {
        if (prossh_export_openssh_private_key(
                private_key,
                passphrase,
                private_key_cipher,
                comment,
                &private_key_output,
                error_buffer,
                error_buffer_len
            ) != 0 || private_key_output == NULL) {
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            ssh_pki_ctx_free(pki_context);
            return -6;
        }
    } else {
        if (has_passphrase && private_key_format != PROSSH_PRIVATE_KEY_OPENSSH) {
            prossh_copy_string(
                error_buffer,
                error_buffer_len,
                "Passphrase encryption is currently supported for OpenSSH private key format only."
            );
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            ssh_pki_ctx_free(pki_context);
            return -6;
        }

        if (ssh_pki_export_privkey_base64_format(
                private_key,
                has_passphrase ? passphrase : NULL,
                NULL,
                NULL,
                &private_key_output,
                prossh_map_private_key_format(private_key_format)
            ) != SSH_OK || private_key_output == NULL) {
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to export private key.");
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            ssh_pki_ctx_free(pki_context);
            return -6;
        }
    }

    char *public_key_base64 = NULL;
    if (ssh_pki_export_pubkey_base64(public_key, &public_key_base64) != SSH_OK || public_key_base64 == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to export public key.");
        if (private_key_uses_malloc) {
            prossh_secure_free_cstring(private_key_output);
        } else {
            ssh_string_free_char(private_key_output);
        }
        ssh_key_free(public_key);
        ssh_key_free(private_key);
        ssh_pki_ctx_free(pki_context);
        return -7;
    }

    const char *public_key_type = ssh_key_type_to_char(ssh_key_type(public_key));
    if (public_key_type == NULL || public_key_type[0] == '\0') {
        public_key_type = "ssh-unknown";
    }

    const char *safe_comment = (comment != NULL) ? comment : "";
    int public_written = snprintf(
        public_key_buffer,
        public_key_buffer_len,
        safe_comment[0] == '\0' ? "%s %s" : "%s %s %s",
        public_key_type,
        public_key_base64,
        safe_comment
    );
    if (public_written < 0 || (size_t)public_written >= public_key_buffer_len) {
        prossh_copy_string(error_buffer, error_buffer_len, "Public key output exceeded buffer size.");
        ssh_string_free_char(public_key_base64);
        if (private_key_uses_malloc) {
            prossh_secure_free_cstring(private_key_output);
        } else {
            ssh_string_free_char(private_key_output);
        }
        ssh_key_free(public_key);
        ssh_key_free(private_key);
        ssh_pki_ctx_free(pki_context);
        return -8;
    }

    char *pkcs8_output = NULL;
    const char *final_private_key = private_key_output;
    if (private_key_format == PROSSH_PRIVATE_KEY_PKCS8) {
        if (has_passphrase) {
            prossh_copy_string(
                error_buffer,
                error_buffer_len,
                "Passphrase encryption is currently unsupported for PKCS#8 export."
            );
            ssh_string_free_char(public_key_base64);
            if (private_key_uses_malloc) {
                prossh_secure_free_cstring(private_key_output);
            } else {
                ssh_string_free_char(private_key_output);
            }
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            ssh_pki_ctx_free(pki_context);
            return -9;
        }

        if (prossh_convert_pem_to_pkcs8(
                private_key_output,
                &pkcs8_output,
                error_buffer,
                error_buffer_len
            ) != 0 || pkcs8_output == NULL) {
            ssh_string_free_char(public_key_base64);
            if (private_key_uses_malloc) {
                prossh_secure_free_cstring(private_key_output);
            } else {
                ssh_string_free_char(private_key_output);
            }
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            ssh_pki_ctx_free(pki_context);
            return -9;
        }
        final_private_key = pkcs8_output;
    }

    prossh_copy_string(private_key_buffer, private_key_buffer_len, final_private_key);

    unsigned char *sha256_hash = NULL;
    size_t sha256_hash_len = 0;
    if (ssh_get_publickey_hash(public_key, SSH_PUBLICKEY_HASH_SHA256, &sha256_hash, &sha256_hash_len) == SSH_OK &&
        sha256_hash != NULL && sha256_hash_len > 0) {
        char *sha256_fingerprint = ssh_get_fingerprint_hash(
            SSH_PUBLICKEY_HASH_SHA256,
            sha256_hash,
            sha256_hash_len
        );
        if (sha256_fingerprint != NULL) {
            prossh_copy_string(
                sha256_fingerprint_buffer,
                sha256_fingerprint_buffer_len,
                sha256_fingerprint
            );
            ssh_string_free_char(sha256_fingerprint);
        }
        ssh_clean_pubkey_hash(&sha256_hash);
    }

    unsigned char *md5_hash = NULL;
    size_t md5_hash_len = 0;
    if (ssh_get_publickey_hash(public_key, SSH_PUBLICKEY_HASH_MD5, &md5_hash, &md5_hash_len) == SSH_OK &&
        md5_hash != NULL && md5_hash_len > 0) {
        char *md5_fingerprint = ssh_get_fingerprint_hash(
            SSH_PUBLICKEY_HASH_MD5,
            md5_hash,
            md5_hash_len
        );
        if (md5_fingerprint != NULL) {
            prossh_copy_string(
                md5_fingerprint_buffer,
                md5_fingerprint_buffer_len,
                md5_fingerprint
            );
            ssh_string_free_char(md5_fingerprint);
        }
        ssh_clean_pubkey_hash(&md5_hash);
    }

    ssh_string_free_char(public_key_base64);
    if (private_key_uses_malloc) {
        prossh_secure_free_cstring(private_key_output);
    } else {
        ssh_string_free_char(private_key_output);
    }
    if (pkcs8_output != NULL) {
        prossh_secure_free_cstring(pkcs8_output);
    }
    ssh_key_free(public_key);
    ssh_key_free(private_key);
    ssh_pki_ctx_free(pki_context);
    return 0;
}

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
) {
    prossh_copy_string(private_key_buffer, private_key_buffer_len, "");
    prossh_copy_string(public_key_buffer, public_key_buffer_len, "");
    prossh_copy_string(key_type_buffer, key_type_buffer_len, "");
    prossh_copy_string(sha256_fingerprint_buffer, sha256_fingerprint_buffer_len, "");
    prossh_copy_string(md5_fingerprint_buffer, md5_fingerprint_buffer_len, "");

    if (bit_length != NULL) {
        *bit_length = -1;
    }
    if (is_private_key != NULL) {
        *is_private_key = 0;
    }
    if (is_passphrase_protected != NULL) {
        *is_passphrase_protected = 0;
    }
    if (detected_private_format != NULL) {
        *detected_private_format = (int)PROSSH_PRIVATE_KEY_OPENSSH;
    }
    if (detected_private_cipher != NULL) {
        *detected_private_cipher = (int)PROSSH_PRIVATE_KEY_CIPHER_NONE;
    }

    char *trimmed = prossh_trimmed_copy(key_input);
    if (trimmed == NULL || trimmed[0] == '\0') {
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "No key text was provided for import.");
        return -1;
    }

    const bool looks_private = strstr(trimmed, "PRIVATE KEY-----") != NULL ||
                               strstr(trimmed, "BEGIN OPENSSH PRIVATE KEY") != NULL;
    const bool looks_public = strncmp(trimmed, "ssh-", 4) == 0 ||
                              strncmp(trimmed, "ecdsa-", 6) == 0 ||
                              strncmp(trimmed, "sk-", 3) == 0;

    const char *normalized_comment = comment != NULL ? comment : "";
    while (*normalized_comment == ' ' || *normalized_comment == '\t') {
        normalized_comment++;
    }

    if (looks_private || !looks_public) {
        ProSSHPrivateKeyFormat format = prossh_detect_private_key_format(trimmed);
        bool encrypted = false;
        ProSSHPrivateKeyCipher cipher = prossh_detect_private_key_cipher(format, trimmed, &encrypted);

        if (detected_private_format != NULL) {
            *detected_private_format = (int)format;
        }
        if (detected_private_cipher != NULL) {
            *detected_private_cipher = (int)cipher;
        }
        if (is_passphrase_protected != NULL) {
            *is_passphrase_protected = encrypted ? 1 : 0;
        }

        const char *effective_passphrase = passphrase;
        if (effective_passphrase != NULL && effective_passphrase[0] == '\0') {
            effective_passphrase = NULL;
        }

        ssh_key private_key = NULL;
        int import_rc = ssh_pki_import_privkey_base64(
            trimmed,
            effective_passphrase,
            NULL,
            NULL,
            &private_key
        );
        if (import_rc != SSH_OK || private_key == NULL) {
            prossh_secure_free_cstring(trimmed);
            if (encrypted && (effective_passphrase == NULL || effective_passphrase[0] == '\0')) {
                prossh_copy_string(
                    error_buffer,
                    error_buffer_len,
                    "This private key is encrypted. Provide a passphrase to import it."
                );
            } else {
                prossh_copy_string(
                    error_buffer,
                    error_buffer_len,
                    "Failed to import private key. Verify the key format and passphrase."
                );
            }
            return -2;
        }

        ssh_key public_key = NULL;
        if (ssh_pki_export_privkey_to_pubkey(private_key, &public_key) != SSH_OK || public_key == NULL) {
            ssh_key_free(private_key);
            prossh_secure_free_cstring(trimmed);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to derive public key from private key.");
            return -3;
        }

        if (prossh_export_authorized_public_key(
                public_key,
                normalized_comment,
                public_key_buffer,
                public_key_buffer_len
            ) != 0) {
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            prossh_secure_free_cstring(trimmed);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to export public key during import.");
            return -4;
        }

        prossh_copy_string(private_key_buffer, private_key_buffer_len, trimmed);

        if (prossh_map_imported_key_type(public_key, key_type_buffer, key_type_buffer_len, bit_length) != 0) {
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            prossh_secure_free_cstring(trimmed);
            prossh_copy_string(error_buffer, error_buffer_len, "Imported key type is unsupported.");
            return -5;
        }

        prossh_fill_key_fingerprints(
            public_key,
            sha256_fingerprint_buffer,
            sha256_fingerprint_buffer_len,
            md5_fingerprint_buffer,
            md5_fingerprint_buffer_len
        );

        if (is_private_key != NULL) {
            *is_private_key = 1;
        }
        if (effective_passphrase != NULL && effective_passphrase[0] != '\0' &&
            is_passphrase_protected != NULL) {
            *is_passphrase_protected = 1;
        }

        ssh_key_free(public_key);
        ssh_key_free(private_key);
        prossh_secure_free_cstring(trimmed);
        return 0;
    }

    const char *cursor = trimmed;
    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }

    const char *type_start = cursor;
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t' && *cursor != '\r' && *cursor != '\n') {
        cursor++;
    }
    const char *type_end = cursor;

    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }
    const char *base64_start = cursor;
    while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t' && *cursor != '\r' && *cursor != '\n') {
        cursor++;
    }
    const char *base64_end = cursor;

    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }
    const char *comment_start = cursor;
    const char *comment_end = trimmed + strlen(trimmed);
    while (comment_end > comment_start &&
           (comment_end[-1] == ' ' || comment_end[-1] == '\t' || comment_end[-1] == '\r' || comment_end[-1] == '\n')) {
        comment_end--;
    }

    char *type_token = prossh_dup_range(type_start, type_end);
    char *base64_token = prossh_dup_range(base64_start, base64_end);
    char *comment_token = prossh_dup_range(comment_start, comment_end);
    if (type_token == NULL || base64_token == NULL) {
        free(type_token);
        free(base64_token);
        free(comment_token);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Public key import parsing failed.");
        return -6;
    }

    if (type_token[0] == '\0' || base64_token[0] == '\0') {
        free(type_token);
        free(base64_token);
        free(comment_token);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid public key format.");
        return -7;
    }

    enum ssh_keytypes_e parsed_type = ssh_key_type_from_name(type_token);
    if (parsed_type == SSH_KEYTYPE_UNKNOWN) {
        free(type_token);
        free(base64_token);
        free(comment_token);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Unsupported public key type.");
        return -8;
    }

    ssh_key public_key = NULL;
    if (ssh_pki_import_pubkey_base64(base64_token, parsed_type, &public_key) != SSH_OK || public_key == NULL) {
        free(type_token);
        free(base64_token);
        free(comment_token);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to import public key.");
        return -9;
    }

    const char *effective_comment = normalized_comment;
    if ((effective_comment == NULL || effective_comment[0] == '\0') &&
        comment_token != NULL && comment_token[0] != '\0') {
        effective_comment = comment_token;
    }

    if (prossh_export_authorized_public_key(
            public_key,
            effective_comment,
            public_key_buffer,
            public_key_buffer_len
        ) != 0) {
        ssh_key_free(public_key);
        free(type_token);
        free(base64_token);
        free(comment_token);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to normalize imported public key.");
        return -10;
    }

    if (prossh_map_imported_key_type(public_key, key_type_buffer, key_type_buffer_len, bit_length) != 0) {
        ssh_key_free(public_key);
        free(type_token);
        free(base64_token);
        free(comment_token);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Imported public key type is unsupported.");
        return -11;
    }

    prossh_fill_key_fingerprints(
        public_key,
        sha256_fingerprint_buffer,
        sha256_fingerprint_buffer_len,
        md5_fingerprint_buffer,
        md5_fingerprint_buffer_len
    );

    if (is_private_key != NULL) {
        *is_private_key = 0;
    }
    if (is_passphrase_protected != NULL) {
        *is_passphrase_protected = 0;
    }
    if (detected_private_format != NULL) {
        *detected_private_format = (int)PROSSH_PRIVATE_KEY_OPENSSH;
    }
    if (detected_private_cipher != NULL) {
        *detected_private_cipher = (int)PROSSH_PRIVATE_KEY_CIPHER_NONE;
    }

    ssh_key_free(public_key);
    free(type_token);
    free(base64_token);
    free(comment_token);
    prossh_secure_free_cstring(trimmed);
    return 0;
}

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
) {
    prossh_copy_string(private_key_buffer, private_key_buffer_len, "");
    prossh_copy_string(public_key_buffer, public_key_buffer_len, "");
    prossh_copy_string(sha256_fingerprint_buffer, sha256_fingerprint_buffer_len, "");
    prossh_copy_string(md5_fingerprint_buffer, md5_fingerprint_buffer_len, "");

    if (output_is_passphrase_protected != NULL) {
        *output_is_passphrase_protected = 0;
    }
    if (output_private_cipher != NULL) {
        *output_private_cipher = (int)PROSSH_PRIVATE_KEY_CIPHER_NONE;
    }

    char *trimmed = prossh_trimmed_copy(private_key_input);
    if (trimmed == NULL || trimmed[0] == '\0') {
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "No private key text was provided for conversion.");
        return -1;
    }

    if (strstr(trimmed, "PRIVATE KEY-----") == NULL &&
        strstr(trimmed, "BEGIN OPENSSH PRIVATE KEY") == NULL) {
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Key conversion requires a private key.");
        return -2;
    }

    const char *effective_input_passphrase = input_passphrase;
    if (effective_input_passphrase != NULL && effective_input_passphrase[0] == '\0') {
        effective_input_passphrase = NULL;
    }

    const char *effective_output_passphrase = output_passphrase;
    if (effective_output_passphrase != NULL && effective_output_passphrase[0] == '\0') {
        effective_output_passphrase = NULL;
    }

    const bool output_is_encrypted = effective_output_passphrase != NULL;

    if (output_is_encrypted && output_private_key_format != PROSSH_PRIVATE_KEY_OPENSSH) {
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(
            error_buffer,
            error_buffer_len,
            "Passphrase encryption is currently supported for OpenSSH output format only."
        );
        return -3;
    }

    ssh_key private_key = NULL;
    int import_rc = ssh_pki_import_privkey_base64(
        trimmed,
        effective_input_passphrase,
        NULL,
        NULL,
        &private_key
    );
    if (import_rc != SSH_OK || private_key == NULL) {
        ProSSHPrivateKeyFormat detected_format = prossh_detect_private_key_format(trimmed);
        bool encrypted = false;
        prossh_detect_private_key_cipher(detected_format, trimmed, &encrypted);

        prossh_secure_free_cstring(trimmed);
        if (encrypted && effective_input_passphrase == NULL) {
            prossh_copy_string(
                error_buffer,
                error_buffer_len,
                "This private key is encrypted. Provide the current passphrase to convert it."
            );
        } else {
            prossh_copy_string(
                error_buffer,
                error_buffer_len,
                "Failed to import private key for conversion. Verify the key format and passphrase."
            );
        }
        return -5;
    }

    ssh_key public_key = NULL;
    if (ssh_pki_export_privkey_to_pubkey(private_key, &public_key) != SSH_OK || public_key == NULL) {
        ssh_key_free(private_key);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to derive public key during conversion.");
        return -6;
    }

    const char *normalized_comment = comment != NULL ? comment : "";
    while (*normalized_comment == ' ' || *normalized_comment == '\t') {
        normalized_comment++;
    }

    if (prossh_export_authorized_public_key(
            public_key,
            normalized_comment,
            public_key_buffer,
            public_key_buffer_len
        ) != 0) {
        ssh_key_free(public_key);
        ssh_key_free(private_key);
        prossh_secure_free_cstring(trimmed);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to export public key during conversion.");
        return -7;
    }

    char *private_key_output = NULL;
    const bool private_key_uses_malloc = output_is_encrypted &&
                                         output_private_key_format == PROSSH_PRIVATE_KEY_OPENSSH;

    if (output_private_key_format == PROSSH_PRIVATE_KEY_OPENSSH && output_is_encrypted) {
        if (prossh_export_openssh_private_key(
                private_key,
                effective_output_passphrase,
                output_private_key_cipher,
                normalized_comment,
                &private_key_output,
                error_buffer,
                error_buffer_len
            ) != 0 || private_key_output == NULL) {
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            prossh_secure_free_cstring(trimmed);
            return -8;
        }
    } else {
        if (ssh_pki_export_privkey_base64_format(
                private_key,
                NULL,
                NULL,
                NULL,
                &private_key_output,
                prossh_map_private_key_format(output_private_key_format)
            ) != SSH_OK || private_key_output == NULL) {
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            prossh_secure_free_cstring(trimmed);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed to export converted private key.");
            return -9;
        }
    }

    char *pkcs8_output = NULL;
    const char *final_private_key = private_key_output;
    if (output_private_key_format == PROSSH_PRIVATE_KEY_PKCS8) {
        if (prossh_convert_pem_to_pkcs8(
                private_key_output,
                &pkcs8_output,
                error_buffer,
                error_buffer_len
            ) != 0 || pkcs8_output == NULL) {
            if (private_key_uses_malloc) {
                prossh_secure_free_cstring(private_key_output);
            } else {
                ssh_string_free_char(private_key_output);
            }
            ssh_key_free(public_key);
            ssh_key_free(private_key);
            prossh_secure_free_cstring(trimmed);
            return -10;
        }
        final_private_key = pkcs8_output;
    }

    prossh_copy_string(private_key_buffer, private_key_buffer_len, final_private_key);
    prossh_fill_key_fingerprints(
        public_key,
        sha256_fingerprint_buffer,
        sha256_fingerprint_buffer_len,
        md5_fingerprint_buffer,
        md5_fingerprint_buffer_len
    );

    if (output_is_passphrase_protected != NULL) {
        *output_is_passphrase_protected = output_is_encrypted ? 1 : 0;
    }
    if (output_private_cipher != NULL) {
        *output_private_cipher = output_is_encrypted
            ? (int)output_private_key_cipher
            : (int)PROSSH_PRIVATE_KEY_CIPHER_NONE;
    }

    if (private_key_uses_malloc) {
        prossh_secure_free_cstring(private_key_output);
    } else {
        ssh_string_free_char(private_key_output);
    }
    if (pkcs8_output != NULL) {
        prossh_secure_free_cstring(pkcs8_output);
    }
    ssh_key_free(public_key);
    ssh_key_free(private_key);
    prossh_secure_free_cstring(trimmed);
    return 0;
}

static char *prossh_shell_single_quote(const char *text) {
    if (text == NULL) {
        return NULL;
    }

    const size_t input_length = strlen(text);
    size_t output_capacity = input_length + 3;
    for (size_t i = 0; i < input_length; i++) {
        if (text[i] == '\'') {
            output_capacity += 3;
        }
    }

    char *quoted = (char *)malloc(output_capacity);
    if (quoted == NULL) {
        return NULL;
    }

    size_t cursor = 0;
    quoted[cursor++] = '\'';
    for (size_t i = 0; i < input_length; i++) {
        if (text[i] == '\'') {
            quoted[cursor++] = '\'';
            quoted[cursor++] = '\\';
            quoted[cursor++] = '\'';
            quoted[cursor++] = '\'';
        } else {
            quoted[cursor++] = text[i];
        }
    }
    quoted[cursor++] = '\'';
    quoted[cursor] = '\0';
    return quoted;
}

static int prossh_execute_remote_command(
    ssh_session session,
    const char *command,
    char *stderr_buffer,
    size_t stderr_buffer_len,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (stderr_buffer != NULL && stderr_buffer_len > 0) {
        stderr_buffer[0] = '\0';
    }

    if (session == NULL || command == NULL || command[0] == '\0') {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid remote command execution parameters.");
        return -1;
    }

    ssh_channel channel = ssh_channel_new(session);
    if (channel == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate SSH channel.");
        return -2;
    }

    if (ssh_channel_open_session(channel) != SSH_OK) {
        const char *session_error = ssh_get_error(session);
        prossh_copy_string(
            error_buffer,
            error_buffer_len,
            (session_error != NULL && session_error[0] != '\0') ? session_error : "Failed to open SSH channel session."
        );
        ssh_channel_free(channel);
        return -3;
    }

    if (ssh_channel_request_exec(channel, command) != SSH_OK) {
        const char *session_error = ssh_get_error(session);
        prossh_copy_string(
            error_buffer,
            error_buffer_len,
            (session_error != NULL && session_error[0] != '\0') ? session_error : "Failed to execute remote SSH command."
        );
        ssh_channel_close(channel);
        ssh_channel_free(channel);
        return -4;
    }

    char read_buffer[512];
    size_t stderr_cursor = 0;

    int read_result = 0;
    while ((read_result = ssh_channel_read(channel, read_buffer, sizeof(read_buffer), 1)) > 0) {
        if (stderr_buffer != NULL && stderr_buffer_len > 1) {
            size_t available = stderr_buffer_len - 1 - stderr_cursor;
            if (available > 0) {
                size_t chunk = (size_t)read_result;
                if (chunk > available) {
                    chunk = available;
                }
                memcpy(stderr_buffer + stderr_cursor, read_buffer, chunk);
                stderr_cursor += chunk;
                stderr_buffer[stderr_cursor] = '\0';
            }
        }
    }

    if (read_result == SSH_ERROR) {
        const char *session_error = ssh_get_error(session);
        prossh_copy_string(
            error_buffer,
            error_buffer_len,
            (session_error != NULL && session_error[0] != '\0') ? session_error : "Failed while reading remote stderr output."
        );
        ssh_channel_close(channel);
        ssh_channel_free(channel);
        return -5;
    }

    while ((read_result = ssh_channel_read(channel, read_buffer, sizeof(read_buffer), 0)) > 0) {
        // Drain stdout to allow command completion.
    }

    if (read_result == SSH_ERROR) {
        const char *session_error = ssh_get_error(session);
        prossh_copy_string(
            error_buffer,
            error_buffer_len,
            (session_error != NULL && session_error[0] != '\0') ? session_error : "Failed while reading remote stdout output."
        );
        ssh_channel_close(channel);
        ssh_channel_free(channel);
        return -6;
    }

    uint32_t exit_code = 0;
    char *exit_signal = NULL;
    int core_dumped = 0;
    ssh_channel_get_exit_state(channel, &exit_code, &exit_signal, &core_dumped);
    ssh_channel_send_eof(channel);
    ssh_channel_close(channel);
    ssh_channel_free(channel);

    if (exit_code != 0) {
        if (stderr_buffer != NULL && stderr_buffer[0] != '\0') {
            prossh_copy_string(error_buffer, error_buffer_len, stderr_buffer);
        } else {
            char status_message[128];
            snprintf(status_message, sizeof(status_message), "Remote command failed with exit status %u.", exit_code);
            prossh_copy_string(error_buffer, error_buffer_len, status_message);
        }
        ssh_string_free_char(exit_signal);
        return -7;
    }
    ssh_string_free_char(exit_signal);

    return 0;
}

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
) {
    if (hostname == NULL || hostname[0] == '\0' ||
        username == NULL || username[0] == '\0' ||
        password == NULL || password[0] == '\0' ||
        public_key_authorized == NULL || public_key_authorized[0] == '\0' ||
        private_key_for_verification == NULL || private_key_for_verification[0] == '\0') {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid ssh-copy-id parameters.");
        return -1;
    }

    ProSSHLibSSHHandle *handle = prossh_libssh_create();
    if (handle == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate SSH handle for ssh-copy-id.");
        return -2;
    }

    int connect_result = prossh_libssh_connect(
        handle,
        hostname,
        port,
        username,
        kex,
        ciphers,
        hostkeys,
        macs,
        timeout_seconds,
        error_buffer,
        error_buffer_len
    );
    if (connect_result != 0) {
        prossh_libssh_destroy(handle);
        return -3;
    }

    int auth_result = prossh_libssh_authenticate(
        handle,
        PROSSH_AUTH_PASSWORD,
        password,
        NULL,
        NULL,
        NULL,
        error_buffer,
        error_buffer_len
    );
    if (auth_result != 0) {
        prossh_libssh_destroy(handle);
        return -4;
    }

    char *quoted_key = prossh_shell_single_quote(public_key_authorized);
    if (quoted_key == NULL) {
        prossh_libssh_destroy(handle);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to prepare public key shell-safe payload.");
        return -5;
    }

    const char *command_template =
        "umask 077 && "
        "mkdir -p ~/.ssh && "
        "touch ~/.ssh/authorized_keys && "
        "chmod 700 ~/.ssh && "
        "chmod 600 ~/.ssh/authorized_keys && "
        "if ! grep -qxF %s ~/.ssh/authorized_keys; then printf '%%s\\n' %s >> ~/.ssh/authorized_keys; fi && "
        "grep -qxF %s ~/.ssh/authorized_keys";

    int command_size = snprintf(NULL, 0, command_template, quoted_key, quoted_key, quoted_key);
    if (command_size < 0) {
        free(quoted_key);
        prossh_libssh_destroy(handle);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to construct remote ssh-copy-id command.");
        return -6;
    }

    char *command = (char *)malloc((size_t)command_size + 1);
    if (command == NULL) {
        free(quoted_key);
        prossh_libssh_destroy(handle);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate remote ssh-copy-id command.");
        return -7;
    }

    snprintf(command, (size_t)command_size + 1, command_template, quoted_key, quoted_key, quoted_key);
    free(quoted_key);

    char stderr_output[1024];
    int execute_result = prossh_execute_remote_command(
        handle->session,
        command,
        stderr_output,
        sizeof(stderr_output),
        error_buffer,
        error_buffer_len
    );
    free(command);
    if (execute_result != 0) {
        prossh_libssh_destroy(handle);
        return -8;
    }

    prossh_libssh_disconnect(handle);
    connect_result = prossh_libssh_connect(
        handle,
        hostname,
        port,
        username,
        kex,
        ciphers,
        hostkeys,
        macs,
        timeout_seconds,
        error_buffer,
        error_buffer_len
    );
    if (connect_result != 0) {
        prossh_libssh_destroy(handle);
        return -9;
    }

    const char *effective_private_key_passphrase = private_key_passphrase;
    if (effective_private_key_passphrase != NULL && effective_private_key_passphrase[0] == '\0') {
        effective_private_key_passphrase = NULL;
    }

    ssh_key private_key = NULL;
    int import_result = ssh_pki_import_privkey_base64(
        private_key_for_verification,
        effective_private_key_passphrase,
        NULL,
        NULL,
        &private_key
    );
    if (import_result != SSH_OK || private_key == NULL) {
        prossh_libssh_destroy(handle);
        prossh_copy_string(
            error_buffer,
            error_buffer_len,
            "Failed to load private key for ssh-copy-id verification. Check key passphrase."
        );
        return -10;
    }

    int verify_auth = ssh_userauth_publickey(handle->session, NULL, private_key);
    ssh_key_free(private_key);
    if (verify_auth != SSH_AUTH_SUCCESS) {
        prossh_libssh_destroy(handle);
        prossh_copy_string(
            error_buffer,
            error_buffer_len,
            "Public key was installed but key-based authentication verification failed."
        );
        return -11;
    }

    prossh_libssh_destroy(handle);
    return 0;
}

int prossh_libssh_sftp_list_directory(
    ProSSHLibSSHHandle *handle,
    const char *remote_path,
    char *output_buffer,
    size_t output_buffer_len,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (output_buffer != NULL && output_buffer_len > 0) {
        output_buffer[0] = '\0';
    }

    if (handle == NULL || handle->session == NULL || remote_path == NULL ||
        output_buffer == NULL || output_buffer_len < 2) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid SFTP list parameters.");
        return -1;
    }

    sftp_session sftp = sftp_new(handle->session);
    if (sftp == NULL) {
        prossh_set_error(handle, "Failed to create SFTP session.", error_buffer, error_buffer_len);
        return -2;
    }

    if (sftp_init(sftp) != SSH_OK) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to initialize SFTP session.");
        sftp_free(sftp);
        return -3;
    }

    sftp_dir dir = sftp_opendir(sftp, remote_path);
    if (dir == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to open remote directory.");
        sftp_free(sftp);
        return -4;
    }

    size_t cursor = 0;
    while (1) {
        sftp_attributes attributes = sftp_readdir(sftp, dir);
        if (attributes == NULL) {
            break;
        }

        const char *name = attributes->name != NULL ? attributes->name : "";
        if (strcmp(name, ".") != 0 && strcmp(name, "..") != 0) {
            const int is_directory = attributes->type == SSH_FILEXFER_TYPE_DIRECTORY ? 1 : 0;
            const unsigned long long file_size = (unsigned long long)attributes->size;
            const unsigned int permissions = attributes->permissions;
            const unsigned long long modified_time = (unsigned long long)attributes->mtime;

            int written = snprintf(
                output_buffer + cursor,
                output_buffer_len - cursor,
                "%s\t%d\t%llu\t%u\t%llu\n",
                name,
                is_directory,
                file_size,
                permissions,
                modified_time
            );

            if (written < 0 || (size_t)written >= (output_buffer_len - cursor)) {
                sftp_attributes_free(attributes);
                sftp_closedir(dir);
                sftp_free(sftp);
                prossh_copy_string(error_buffer, error_buffer_len, "SFTP listing output exceeded buffer size.");
                return -5;
            }

            cursor += (size_t)written;
        }

        sftp_attributes_free(attributes);
    }

    sftp_closedir(dir);
    sftp_free(sftp);
    return 0;
}

int prossh_libssh_sftp_download_file(
    ProSSHLibSSHHandle *handle,
    const char *remote_path,
    const char *local_path,
    int64_t *bytes_transferred,
    int64_t *total_bytes,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (bytes_transferred != NULL) {
        *bytes_transferred = 0;
    }
    if (total_bytes != NULL) {
        *total_bytes = 0;
    }

    if (handle == NULL || handle->session == NULL || remote_path == NULL || local_path == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid SFTP download parameters.");
        return -1;
    }

    sftp_session sftp = sftp_new(handle->session);
    if (sftp == NULL) {
        prossh_set_error(handle, "Failed to create SFTP session.", error_buffer, error_buffer_len);
        return -2;
    }

    if (sftp_init(sftp) != SSH_OK) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to initialize SFTP session.");
        sftp_free(sftp);
        return -3;
    }

    sftp_file remote = sftp_open(sftp, remote_path, O_RDONLY, 0);
    if (remote == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to open remote file for download.");
        sftp_free(sftp);
        return -4;
    }

    sftp_attributes attributes = sftp_fstat(remote);
    if (attributes != NULL && total_bytes != NULL) {
        *total_bytes = (int64_t)attributes->size;
    }
    if (attributes != NULL) {
        sftp_attributes_free(attributes);
    }

    FILE *local = fopen(local_path, "wb");
    if (local == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to open local file for download.");
        sftp_close(remote);
        sftp_free(sftp);
        return -5;
    }

    char buffer[32768];
    int64_t transferred = 0;
    while (1) {
        ssize_t read_count = sftp_read(remote, buffer, sizeof(buffer));
        if (read_count < 0) {
            prossh_copy_string(error_buffer, error_buffer_len, "Failed while reading remote file.");
            fclose(local);
            sftp_close(remote);
            sftp_free(sftp);
            return -6;
        }

        if (read_count == 0) {
            break;
        }

        size_t written = fwrite(buffer, 1, (size_t)read_count, local);
        if (written != (size_t)read_count) {
            prossh_copy_string(error_buffer, error_buffer_len, "Failed while writing local file.");
            fclose(local);
            sftp_close(remote);
            sftp_free(sftp);
            return -7;
        }

        transferred += (int64_t)read_count;
        if (bytes_transferred != NULL) {
            *bytes_transferred = transferred;
        }
    }

    fclose(local);
    sftp_close(remote);
    sftp_free(sftp);
    return 0;
}

int prossh_libssh_sftp_upload_file(
    ProSSHLibSSHHandle *handle,
    const char *local_path,
    const char *remote_path,
    int64_t *bytes_transferred,
    int64_t *total_bytes,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (bytes_transferred != NULL) {
        *bytes_transferred = 0;
    }
    if (total_bytes != NULL) {
        *total_bytes = 0;
    }

    if (handle == NULL || handle->session == NULL || remote_path == NULL || local_path == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid SFTP upload parameters.");
        return -1;
    }

    struct stat local_stat;
    if (stat(local_path, &local_stat) == 0 && total_bytes != NULL) {
        *total_bytes = (int64_t)local_stat.st_size;
    }

    FILE *local = fopen(local_path, "rb");
    if (local == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to open local file for upload.");
        return -2;
    }

    sftp_session sftp = sftp_new(handle->session);
    if (sftp == NULL) {
        fclose(local);
        prossh_set_error(handle, "Failed to create SFTP session.", error_buffer, error_buffer_len);
        return -3;
    }

    if (sftp_init(sftp) != SSH_OK) {
        fclose(local);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to initialize SFTP session.");
        sftp_free(sftp);
        return -4;
    }

    sftp_file remote = sftp_open(
        sftp,
        remote_path,
        O_WRONLY | O_CREAT | O_TRUNC,
        S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
    );
    if (remote == NULL) {
        fclose(local);
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to open remote file for upload.");
        sftp_free(sftp);
        return -5;
    }

    char buffer[32768];
    int64_t transferred = 0;
    while (1) {
        size_t read_count = fread(buffer, 1, sizeof(buffer), local);
        if (read_count == 0) {
            if (ferror(local)) {
                fclose(local);
                sftp_close(remote);
                sftp_free(sftp);
                prossh_copy_string(error_buffer, error_buffer_len, "Failed while reading local file.");
                return -6;
            }
            break;
        }

        ssize_t written = sftp_write(remote, buffer, read_count);
        if (written < 0 || (size_t)written != read_count) {
            fclose(local);
            sftp_close(remote);
            sftp_free(sftp);
            prossh_copy_string(error_buffer, error_buffer_len, "Failed while writing remote file.");
            return -7;
        }

        transferred += (int64_t)written;
        if (bytes_transferred != NULL) {
            *bytes_transferred = transferred;
        }
    }

    fclose(local);
    sftp_close(remote);
    sftp_free(sftp);
    return 0;
}

ProSSHForwardChannel *prossh_forward_channel_open(
    ProSSHLibSSHHandle *handle,
    const char *remote_host,
    uint16_t remote_port,
    const char *source_host,
    uint16_t source_port,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (handle == NULL || handle->session == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "SSH session is not connected.");
        return NULL;
    }

    ssh_channel channel = ssh_channel_new(handle->session);
    if (channel == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to create forward channel.");
        return NULL;
    }

    int rc = ssh_channel_open_forward(
        channel,
        remote_host,
        (int)remote_port,
        source_host,
        (int)source_port
    );

    if (rc != SSH_OK) {
        prossh_set_error(handle, "Failed to open forward channel.", error_buffer, error_buffer_len);
        ssh_channel_free(channel);
        return NULL;
    }

    ProSSHForwardChannel *fwd = (ProSSHForwardChannel *)calloc(1, sizeof(ProSSHForwardChannel));
    if (fwd == NULL) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed to allocate forward channel struct.");
        ssh_channel_close(channel);
        ssh_channel_free(channel);
        return NULL;
    }

    fwd->channel = channel;
    ssh_channel_set_blocking(channel, 0);
    return fwd;
}

int prossh_forward_channel_read(
    ProSSHForwardChannel *fwd,
    char *buffer,
    size_t buffer_len,
    bool *is_eof,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (is_eof != NULL) {
        *is_eof = false;
    }

    if (fwd == NULL || fwd->channel == NULL || buffer == NULL || buffer_len == 0) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid forward channel read parameters.");
        return -1;
    }

    int nbytes = ssh_channel_read_nonblocking(fwd->channel, buffer, (uint32_t)buffer_len, 0);

    if (nbytes == SSH_ERROR) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed reading from forward channel.");
        return -1;
    }

    if (is_eof != NULL) {
        *is_eof = ssh_channel_is_eof(fwd->channel) != 0;
    }

    return nbytes < 0 ? 0 : nbytes;
}

int prossh_forward_channel_write(
    ProSSHForwardChannel *fwd,
    const char *data,
    size_t data_len,
    char *error_buffer,
    size_t error_buffer_len
) {
    if (fwd == NULL || fwd->channel == NULL || data == NULL || data_len == 0) {
        prossh_copy_string(error_buffer, error_buffer_len, "Invalid forward channel write parameters.");
        return -1;
    }

    int written = ssh_channel_write(fwd->channel, data, (uint32_t)data_len);
    if (written == SSH_ERROR) {
        prossh_copy_string(error_buffer, error_buffer_len, "Failed writing to forward channel.");
        return -1;
    }

    return 0;
}

int prossh_forward_channel_is_open(ProSSHForwardChannel *fwd) {
    if (fwd == NULL || fwd->channel == NULL) {
        return 0;
    }
    if (ssh_channel_is_eof(fwd->channel) != 0) {
        return 0;
    }
    if (ssh_channel_is_open(fwd->channel) == 0) {
        return 0;
    }
    return 1;
}

void prossh_forward_channel_close(ProSSHForwardChannel *fwd) {
    if (fwd == NULL) {
        return;
    }

    if (fwd->channel != NULL) {
        ssh_channel_send_eof(fwd->channel);
        ssh_channel_close(fwd->channel);
        ssh_channel_free(fwd->channel);
        fwd->channel = NULL;
    }

    free(fwd);
}
