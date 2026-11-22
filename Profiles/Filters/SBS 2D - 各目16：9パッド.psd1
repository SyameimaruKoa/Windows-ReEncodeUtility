<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04">
  <Obj RefId="0">
    <TN RefId="0">
      <T>System.Collections.Hashtable</T>
      <T>System.Object</T>
    </TN>
    <DCT>
      <En>
        <S N="Key">AdditionalVF</S>
        <S N="Value"></S>
      </En>
      <En>
        <S N="Key">TemplateType</S>
        <S N="Value">Filter</S>
      </En>
      <En>
        <S N="Key">AdditionalArgs</S>
        <S N="Value">-filter_complex "[0:v]split=2[left_src][right_src];[left_src]crop=iw/2:ih:0:0,pad=w=2*ceil(max(iw\,ih*16/9)/2):h=2*ceil(max(ih\,iw*9/16)/2):x=2*floor((ow-iw)/4):y=2*floor((oh-ih)/4):color=black,setsar=1[left_pad];[right_src]crop=iw/2:ih:iw/2:0,pad=w=2*ceil(max(iw\,ih*16/9)/2):h=2*ceil(max(ih\,iw*9/16)/2):x=2*floor((ow-iw)/4):y=2*floor((oh-ih)/4):color=black,setsar=1[right_pad];[left_pad][right_pad]hstack=inputs=2,setsar=1[v]" -map "[v]" -map 0:a? -metadata:s:v:0 stereo_mode=left_right</S>
      </En>
    </DCT>
  </Obj>
</Objs>