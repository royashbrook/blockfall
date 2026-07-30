#include "engine_c_api.h"

int main(void) {
    return bf_abi_version() == BF_ABI_VERSION ? 0 : 1;
}
