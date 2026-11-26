find_converter() {
    local executable
    executable=$(command -v -- "${ENROOT_CONVERTER:-$1/target/debug/enroot-to-oci}") &&
        [[ -f $executable && -x $executable ]] || {
            echo "Build enroot-to-oci with cargo build --locked or set ENROOT_CONVERTER to its executable" >&2
            return 1
        }
    converter=("$executable")
}
