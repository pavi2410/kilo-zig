# kilo-zig

A Zig port of the Kilo text editor tutorial in 1000 lines.

![kilo-zig screenshot](.github/image.png)

```sh
$ tokei --sort=lines -f -c=24 src/main.zig
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Language              Files        Lines         Code     Comments       Blanks
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Zig                       1         1002          954            0           48
─────────────────────────────────────────────────────────────────────────────────
 src/main.zig                        1002          954            0           48
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Total                     1         1002          954            0           48
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Run

```sh
zig build run -- ./build.zig
```

## Credits

- [antirez](https://github.com/antirez), the original author of Kilo
- [viewsourcecode.org Kilo tutorial](https://viewsourcecode.org/snaptoken/kilo/index.html)
