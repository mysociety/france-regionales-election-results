# frozen_string_literal: true

require 'bundler/setup'
require 'require_all'
require 'scraped'
require 'scraperwiki'
require 'table_unspanner'
require 'active_support'
require 'active_support/core_ext/string'
require 'csv'

# require 'open-uri/cached'
# OpenURI::Cache.cache_path = '.cache'

# require_rel 'lib'

def scrape(h)
  url, klass = h.to_a.first
  klass.new(response: Scraped::Request.new(url: url).response)
end

REGION_NAME_MAPPING = CSV.read('region-name-mapping.csv').drop(1).map(&:reverse).to_h

class PartyListPage < Scraped::HTML
  field :party_lookup do
    noko.css('.tableau-nuances tr').map { |row| row.css('td').map(&:text) }.to_h
  end
end

class ElectionResultsPage < Scraped::HTML
  field :region_urls do
    noko.css('#listeRG option/@value').drop(1).map do |result_url|
      URI.join(url, result_url.to_s.gsub(%r{/(\d+)\.}, '/CR\1.')).to_s
    end
  end
end

class CouncilMember < Scraped::HTML
  field :id do
    name.parameterize
  end

  field :name do
    tds.size == 3 ? tds[2].text : tds[1].text
  end

  field :election_area do
    tds.size == 3 ? tds[1].text : ''
  end

  field :region_insee_code do
    url.split('/')[-2]
  end

  field :party_code do
    tds[0].text.match(/\((\w+)\)/)[1]
  end

  field :gender do
    name.match(/^M\. /) ? 'M' : name.gsub(/^Mme /) ? 'F' : ''
  end

  private

  def tds
    noko.css('td')
  end
end

class RegionResultsPage < Scraped::HTML
  field :councillors do
    table.xpath('.//tr[td]').map do |row|
      fragment(row => CouncilMember)
    end
  end

  field :name do
    REGION_NAME_MAPPING.fetch(noko.at_css('h2').text.gsub('Conseil Régional de la région : ', ''))
  end

  private

  def table
    @table ||= TableUnspanner::UnspannedTable.new(noko.at_css('table')).nokogiri_node
  end
end

parties_url = 'https://www.interieur.gouv.fr/Elections/Les-resultats/Regionales/elecresult__regionales-2015/(path)/regionales-2015/nuances.html'
parties = scrape(parties_url => PartyListPage).party_lookup

results_url = 'https://www.interieur.gouv.fr/Elections/Les-resultats/Regionales/elecresult__regionales-2015/(path)/regionales-2015/index.html'
page = scrape(results_url => ElectionResultsPage)

page.region_urls.each do |url|
  region = scrape(url => RegionResultsPage)
  region.councillors.each do |c|
    ScraperWiki.save_sqlite([:id], c.to_h.merge(party: parties[c.party_code], region: region.name))
  end
end
