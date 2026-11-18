// vaprofiles (host video): the decode profiles the host's VA-API driver offers.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_str.h>
int main(void) {
    int fd = open("/dev/dri/renderD128", O_RDWR);
    VADisplay d = vaGetDisplayDRM(fd);
    int maj, min;
    if (vaInitialize(d, &maj, &min) != VA_STATUS_SUCCESS) {
        printf("vaInitialize failed\n");
        return 1;
    }
    printf("VA-API %d.%d, %s\n", maj, min, vaQueryVendorString(d));
    int n = vaMaxNumProfiles(d);
    VAProfile *p = calloc((size_t)n, sizeof(*p));
    vaQueryConfigProfiles(d, p, &n);
    for (int i = 0; i < n; i++) {
        int ne = vaMaxNumEntrypoints(d);
        VAEntrypoint *e = calloc((size_t)ne, sizeof(*e));
        vaQueryConfigEntrypoints(d, p[i], e, &ne);
        for (int k = 0; k < ne; k++) {
            if (e[k] == VAEntrypointEncSlice || e[k] == VAEntrypointEncSliceLP) {   // 0.1.2: hardware encoding
                printf("  encode%s: %s\n", e[k] == VAEntrypointEncSliceLP ? " (low power)" : "", vaProfileStr(p[i]));
            }
            if (e[k] == VAEntrypointVLD) {
                printf("  decode: %s\n", vaProfileStr(p[i]));
            }
        }
        free(e);
    }
    return 0;
}
