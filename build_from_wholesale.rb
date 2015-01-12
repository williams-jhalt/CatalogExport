#!/usr/bin/env ruby

require 'net/http'
require 'fileutils'
require 'ox'
require 'csv'
require 'htmlentities'
require 'securerandom'
require 'open-uri'
require 'digest'
require 'nokogiri'

class ProductXmlReader < ::Ox::Sax

	def initialize()
		@manufacturers = {}
		@productTypes = {}
		@categories = {}
		@products = []
		@productImages = {}
		@descriptions = {}
		@decoder = HTMLEntities.new
	end

	def start_element(name)
		@currentElement = name.to_s.strip
		@currentText = nil
		case @currentElement
			when "product"
				@currentProduct = Hash.new
				@currentImages = Array.new
				@currentCategories = Array.new
		end
	end

	def end_element(name)
		case name.to_s.strip
			# gather up the fields
			when "sku"
				@currentProduct[:sku] = @currentText
			when "name"
				@currentProduct[:name] = @currentCdata
			when "height"
				@currentProduct[:height] = @currentText
			when "length"
				@currentProduct[:length] = @currentText
			when "diameter"
				@currentProduct[:width] = @currentText
			when "weight"
				@currentProduct[:weight] = @currentText
			when "color"
				@currentProduct[:color] = @currentText
			when "material"
				@currentProduct[:material] = @currentText
			when "barcode"
				@currentProduct[:upc] = @currentText
			when "stock_quantity"
				@currentProduct[:stock_quantity] = @currentText
			when "release_date"
				@currentProduct[:release_date] = Date.parse(@currentText)
			when "description"
				@descriptions[@currentProduct[:sku]] = @currentCdata
			# collect images
			when "image"
				@currentImages << "http://images.williams-trading.com/product_images#{@currentText}"
			# add collected images to product
			when "images"
				@currentProduct[:images] = @currentImages
			# add to products
			when "product"
				@products << @currentProduct
			# add to products and collect for export
			when "manufacturer"
				@currentProduct[:manufacturer] = @currentManufacturerCode
				@manufacturers[@currentManufacturerCode] = @currentText
			when "type"
				@currentProduct[:productType] = @currentProductTypeCode
				@productTypes[@currentProductTypeCode] = @currentText
			when "category"
				@currentCategories << @currentCategoryCode
				@categories[@currentCategoryCode] = { parent: @currentCategoryParent, name: @currentText }
			when "categories"
				@currentProduct[:categories] = @currentCategories
		end
	end

	def attr(name, value)
		case @currentElement
			when "manufacturer"
				if name.to_s.strip == 'code'
				@currentManufacturerCode = value.strip
				end
			when "type"
				if name.to_s.strip == 'code'
				@currentProductTypeCode = value.strip
				end
			when "category"
				if name.to_s.strip == 'code'
				@currentCategoryCode = value.strip
				end
				if name.to_s.strip == 'parent'
				@currentCategoryParent = value.strip
				end
		end
	end

	def text(value)
		@currentText = @decoder.decode(value.strip)
	end

	def cdata(value)
		@currentCdata = value.strip
	end

	def products
		@products
	end

	def categories
		@categories
	end

	def manufacturers
		@manufacturers
	end

	def productTypes
		@productTypes
	end
	
	def descriptions
		@descriptions
	end

end

class DownloadExporter

	attr_accessor :handler

	def initialize
		
		unless File.exist?("./downloads")
			FileUtils.mkdir("./downloads")
		end
		
		unless File.exist?("./export")
			FileUtils.mkdir("./export")
		end

		@handler = ProductXmlReader.new()
		
	end

	def write_csv_files
		puts "Begin parsing file ... "
		parse
		puts "complete!"
		puts "Begin writing products.csv ... "
		write_products
		puts "complete!"
		puts "Begin writing product_details.csv ... "
		write_product_details
		puts "complete!"
		puts "Begin writing manufacturers.csv ... "
		write_manufacturers
		puts "complete!"
		puts "Begin writing product_types.csv ... "
		write_product_types
		puts "complete!"
		puts "Begin writing categories.csv ... "
		write_category_tree
		puts "complete!"
		puts "Begin writing categories_flat.csv ... "
		write_categories
		puts "complete!"
		puts "Begin writing descriptions ... "
		write_product_descriptions
		puts "complete!"
		puts "Begin writing product_images.csv and downloading new images ... "
		write_product_images
		puts "complete!"
	end

	protected

	def write_products
		CSV.open("./export/products.csv", "wb") do |csv|
			csv << [ "sku", "name", "release_date", "stock_quantity", "manufacturer", "product_type", "categories", "upc" ]
			handler.products.each do |product|
				csv << [
					product[:sku],
					product[:name],
					product[:release_date].strftime('%F'),
					product[:stock_quantity],
					product[:manufacturer],
					product[:productType],
					product[:categories].join('|'),
					product[:upc]
				]
			end
		end
	end

	def write_product_details
		CSV.open("./export/product_details.csv", "wb") do |csv|
			csv << [ "sku", "height", "length", "width", "weight", "color", "material", "upc" ]
			handler.products.each do |product|
				csv << [
					product[:sku],
					product[:height],
					product[:length],
					product[:width],
					product[:weight],
					product[:color],
					product[:material],
					product[:upc]
				]
			end
		end
	end

	def write_manufacturers
		CSV.open("./export/manufacturers.csv", "wb") do |csv|
			csv << [ "code", "name" ]
			handler.manufacturers.each do |key, value|
				csv << [ key, value ]
			end
		end
	end

	def write_product_types
		CSV.open("./export/product_types.csv", "wb") do |csv|
			csv << [ "code", "name" ]
			handler.productTypes.each do |key, value|
				csv << [ key, value ]
			end
		end
	end

	def write_categories
		CSV.open("./export/categories_flat.csv", "wb") do |csv|
			csv << [ "code", "name" ]
			handler.categories.each do |key, value|
				csv << [ key, find_full_category_path(handler.categories, key) ]
			end
		end
	end

	def write_category_tree
		CSV.open("./export/categories.csv", "wb") do |csv|
			csv << [ "code", "name", "parent" ]
			handler.categories.each do |key, value|
				csv << [ key, value[:name], value[:parent] ]
			end
		end
	end

	def write_product_images
		downloads = []
		CSV.open("./export/product_images.csv", "wb") do |csv|
			csv << [ "sku", "filename", "original_filename" ]
			for product in handler.products
				FileUtils.mkdir_p("./export/images/#{product[:sku]}") unless File.exist?("./export/images/#{product[:sku]}")
				product[:images].each do |image|
					original_filename = File.basename(image)
					filename = Digest::MD5.hexdigest(product[:sku] + "::" + original_filename) + File.extname(image)		  
					csv << [ product[:sku], filename, original_filename ]
					unless File.exist?("./export/images/#{product[:sku]}/#{filename}")
						downloads << { :url => image, :outfile => "./export/images/#{product[:sku]}/#{filename}" }
					end
				end
			end	  
		end
		multi_http_download(downloads, 5)
	end
	
	def write_product_descriptions
		for key, value in handler.descriptions
			FileUtils.mkdir_p("./export/descriptions/#{key}") unless File.exist?("./export/images/#{key}")		
			File.open("./export/descriptions/#{key}/description.txt", "w+") do |file| 
				file.write(value)
			end
		end
	end

	def parse
		infile = download
		Ox.sax_parse(handler, File.open(infile))
	end

	def download
		outfile = "./downloads/products.xml"

		if !File.exist?("./downloads/products.xml") or Time.now > File.mtime("./downloads/products.xml") + 3600
			puts "File was outdated, fetching ... "
			Net::HTTP.start("downloads.williams-trading.com") do |http|
				resp = http.get("/export/wholesale/products.xml")
				open(outfile, "w") do |file|
					file.write(resp.body)
				end
			end
			puts "completed download"
		end

		return outfile
	end

	def multi_http_download(urls, thread_count)
		queue = Queue.new
		urls.map { |url| queue << url }

		threads = thread_count.times.map do
			Thread.new do
				Net::HTTP.start('images.williams-trading.com.s3.amazonaws.com', 80) do |http|
					while !queue.empty? && url = queue.pop
						uri = URI(url[:url])
						resp = http.get(uri.path)
						open(url[:outfile], "wb") do |file|
							file.write(resp.body)
						end
					end
				end
			end
		end

		threads.each(&:join)
	end

	def write_product_image(sku, filename, image)
		open("./export/images/#{sku}/#{filename}", "wb") do |file|
			file << open(image).read
		end
	end

	def find_full_category_path(categories, code)
		category = categories[code]
		name = category[:name]
		parent = category[:parent]
		while parent != "0"
			parentCategory = categories[parent]
			name.prepend("#{parentCategory[:name]} / ")
			parent = parentCategory[:parent]
		end
		return name
	end

end # class DownloadExporter

DownloadExporter.new.write_csv_files
