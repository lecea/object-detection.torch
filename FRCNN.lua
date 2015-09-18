local flipBoundingBoxes = paths.dofile('utils.lua').flipBoundingBoxes
local FRCNN = torch.class('nnf.FRCNN')

function FRCNN:__init()
  
  self.image_transformer = nnf.ImageTransformer{}
  self.scale = {600}
  self.max_size = 1000
  self.randomscale = true
  
  --self.inputArea = 224^2
end

function FRCNN:processImages(output_imgs,input_imgs,do_flip)
  local num_images = #input_imgs

  local imgs = {}
  local im_sizes = {}
  local im_scales = {}

  for i=1,num_images do
    local im = input_imgs[i]
    im = self.image_transformer:preprocess(im)
    local flip = do_flip and (do_flip[i] == 1) or false
    if flip then
      im = image.hflip(im)
    end
    local scale = self.scale[math.random(1,#self.scale)]
    local im_size = im[1]:size()
    local im_size_min = math.min(im_size[1],im_size[2])
    local im_size_max = math.max(im_size[1],im_size[2])
    local im_scale = scale/im_size_min
    if torch.round(im_scale*im_size_max) > self.max_size then
       im_scale = self.max_size/im_size_max
    end
    local im_s = {torch.round(im_size[1]*im_scale),torch.round(im_size[2]*im_scale)}
    table.insert(imgs,image.scale(im,im_s[2],im_s[1]))
    table.insert(im_sizes,im_s)
    table.insert(im_scales,im_scale)
  end
  -- create single tensor with all images, padding with zero for different sizes
  im_sizes = torch.IntTensor(im_sizes)
  local max_shape = im_sizes:max(1)[1]
  output_imgs:resize(num_images,3,max_shape[1],max_shape[2]):zero()
  for i=1,num_images do
    output_imgs[i][{{},{1,imgs[i]:size(2)},{1,imgs[i]:size(3)}}]:copy(imgs[i])
  end
  return im_scales,im_sizes
end

-- only for single image ATM, not working yet
local function project_im_rois_eval(im_rois,scales)
  local levels
  local rois = torch.FloatTensor()
  if #scales > 1 then
    local scales = torch.FloatTensor(scales)
    local widths = im_rois[{{},3}] - im_rois[{{},1}] + 1
    local heights = im_rois[{{},4}] - im_rois[{{}, 2}] + 1

    local areas = widths * heights
    local scaled_areas = areas:view(-1,1) * torch.pow(scales:view(1,-1),2)
    local diff_areas = torch.abs(scaled_areas - 224 * 224)
    levels = select(2, diff_areas:min(2))
  else
    levels = torch.FloatTensor()
    rois:resize(im_rois:size(1),5)
    rois[{{},1}]:fill(1)
    rois[{{},{2,5}}]:copy(im_rois):add(-1):mul(scales[1]):add(1)
  end

  return rois
end


local function project_im_rois(rois,im_rois,scales,do_flip,imgs_size)
  local total_bboxes = 0
  local cumul_bboxes = {0}
  for i=1,#scales do
    total_bboxes = total_bboxes + im_rois[i]:size(1)
    table.insert(cumul_bboxes,total_bboxes)
  end
  rois:resize(total_bboxes,5)
  for i=1,#scales do
    local idx = {cumul_bboxes[i]+1,cumul_bboxes[i+1]}
    rois[{idx,1}]:fill(i)
    rois[{idx,{2,5}}]:copy(im_rois[i]):add(-1):mul(scales[i]):add(1)
    if do_flip and do_flip[i] == 1 then
      flipBoundingBoxes(rois[{idx,{2,5}}],imgs_size[{i,2}])
    end
  end
  return rois
end

function FRCNN:getFeature(imgs,bboxes,flip)
  --local flip = flip==nil and false or flip

  self._feat = self._feat or {torch.FloatTensor(),torch.FloatTensor()}

  if torch.isTensor(imgs) then
    imgs = {imgs}
    if type(bboxes) == 'table' then
      bboxes = torch.FloatTensor(bboxes)
      bboxes = bboxes:dim() == 1 and {bboxes:view(1,-1)} or {bboxes}
    end
    if flip == false then
      flip = {0}
    elseif flip == true then
      flip = {1}
    end
  end

  local im_scales, im_sizes = self:processImages(self._feat[1],imgs,flip)
  project_im_rois(self._feat[2],bboxes,im_scales,flip,im_sizes)
  
  return self._feat
end

