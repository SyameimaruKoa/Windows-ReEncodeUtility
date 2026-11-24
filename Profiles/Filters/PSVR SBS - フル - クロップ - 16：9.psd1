<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
<Obj RefId="0">
<TN RefId="0">
<T>System.Collections.Hashtable</T>
<T>System.Object</T>
</TN>
<DCT>
<En>
<S N="Key">TemplateType</S>
<S N="Value">Filter</S>
</En>
<En>
<S N="Key">AdditionalVF</S>
<S N="Value"></S>
</En>
<En>
<S N="Key">AdditionalArgs</S>
<S N="Value">-filter_complex "[0:v]crop=iw/2:ih:0:0[left_raw];[0:v]crop=iw/2:ih:iw/2:0[right_raw];[left_raw]lenscorrection=cx=0.5:cy=0.5:k1=-0.16:k2=-0.16[left_corrected];[right_raw]lenscorrection=cx=0.5:cy=0.5:k1=-0.16:k2=-0.16[right_corrected];[left_corrected]crop=iw:iw*9/16[left_cropped];[right_corrected]crop=iw:iw*9/16[right_cropped];[left_cropped][right_cropped]hstack[out]" -map "[out]" -map 0:a? -metadata:s:v:0 stereo_mode=left_right</S>
</En>
</DCT>
</Obj>
</Objs>
