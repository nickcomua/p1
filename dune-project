(lang dune 3.16)

(name p1)

(generate_opam_files true)

(source
 (github nickcomua/p1))

(authors "Mykola Korniichuk")
(maintainers "Mykola Korniichuk")
(license MIT)
(package
 (name p1)
 (synopsis "A short synopsis")
 (description "TCP server and clients")
 (depends ocaml logs lwt))
