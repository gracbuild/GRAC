(function (window) {
    "use strict";

    if (window.Swal || typeof window.swal !== "function") {
        return;
    }

    function normalizeOptions(options, text, icon) {
        if (typeof options === "string") {
            return {
                title: options,
                text: text || "",
                type: icon || ""
            };
        }

        options = options || {};
        return {
            title: options.title || "",
            text: options.text || options.html || "",
            type: options.icon || options.type || "",
            showCancelButton: !!options.showCancelButton,
            confirmButtonText: options.confirmButtonText || "OK",
            cancelButtonText: options.cancelButtonText || "Cancel",
            allowEscapeKey: options.allowEscapeKey !== false,
            allowOutsideClick: options.allowOutsideClick === true,
            closeOnConfirm: true,
            closeOnCancel: true,
            html: !!options.html
        };
    }

    window.Swal = {
        fire: function (options, text, icon) {
            return new Promise(function (resolve) {
                var swalOptions = normalizeOptions(options, text, icon);

                window.swal(swalOptions, function (isConfirm) {
                    resolve({
                        isConfirmed: isConfirm !== false,
                        isDismissed: isConfirm === false,
                        value: isConfirm
                    });
                });
            });
        }
    };
})(window);
