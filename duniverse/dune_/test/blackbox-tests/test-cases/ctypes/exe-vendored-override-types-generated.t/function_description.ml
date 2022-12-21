open Ctypes

module Types = My_generated_types

module Functions (F : Ctypes.FOREIGN) = struct
  open F
  let add2 = foreign "example_add2" (int @-> returning int)
end
