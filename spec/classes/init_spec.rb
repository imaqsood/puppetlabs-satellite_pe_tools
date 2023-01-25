# frozen_string_literal: true

require 'spec_helper'
describe 'satellite_pe_tools' do
  context 'with defaults for all parameters' do
    let(:pre_condition) { "service { 'pe-puppetserver': }" }
    let(:params) { { satellite_url: 'https://127.0.0.1' } }
    let(:facts) { { os: { family: 'RedHat' } } }

    it { is_expected.to contain_class('satellite_pe_tools') }
  end
end
